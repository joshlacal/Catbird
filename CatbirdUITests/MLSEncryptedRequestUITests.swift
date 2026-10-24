import XCTest

final class MLSEncryptedRequestUITests: XCTestCase {
  @MainActor
  func testIncomingPreviewAndAcceptancePresentation() {
    let app = XCUIApplication()
    app.launchArguments += ["--encrypted-request-ui-fixture"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Hello, Bob"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["Accept"].exists)
    XCTAssertTrue(app.buttons["Decline"].exists)
    XCTAssertTrue(app.buttons["Block"].exists)
    XCTAssertFalse(app.textViews["Message composer"].exists)
    let before = XCTAttachment(screenshot: app.screenshot())
    before.name = "incoming-request-presentation"
    before.lifetime = .keepAlways
    add(before)
    app.buttons["Accept"].tap()
    XCTAssertTrue(app.textViews["Message composer"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts.matching(identifier: "request-first-message").count, 1)
    let after = XCTAttachment(screenshot: app.screenshot())
    after.name = "accepted-presentation-only"
    after.lifetime = .keepAlways
    add(after)
  }

  @MainActor
  func testOutgoingHasOneIntroductionAndNoComposer() {
    let app = XCUIApplication()
    app.launchArguments += ["--encrypted-request-ui-fixture", "--request-outgoing"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Request sent"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts.matching(identifier: "request-first-message").count, 1)
    XCTAssertFalse(app.textViews["Message composer"].exists)
    XCTAssertFalse(app.buttons["Accept"].exists)
  }
  @MainActor
  func testAcceptingNoteDoesNotAcceptGroupInvitation() {
    let app = XCUIApplication()
    app.launchArguments += ["--encrypted-request-ui-fixture", "--request-invitation"]
    app.launch()
    XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["View group invitation"].exists)
    let pending = XCTAttachment(screenshot: app.screenshot())
    pending.name = "invitation-pending-presentation"
    pending.lifetime = .keepAlways
    add(pending)
    app.buttons["Accept"].tap()
    XCTAssertTrue(app.textViews["Message composer"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["fixture-group-pending"].exists)
    let accepted = XCTAttachment(screenshot: app.screenshot())
    accepted.name = "invitation-accepted-presentation"
    accepted.lifetime = .keepAlways
    add(accepted)
    app.buttons["View group invitation"].tap()
    XCTAssertTrue(app.staticTexts["fixture-group-pending"].waitForExistence(timeout: 5))
    let group = XCTAttachment(screenshot: app.screenshot())
    group.name = "invitation-group-pending-presentation"
    group.lifetime = .keepAlways
    add(group)
  }

}
