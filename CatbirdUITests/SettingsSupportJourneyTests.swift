import XCTest

/// Exercises real Settings views using isolated local state. No authenticated account or purchase.
final class SettingsSupportJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDownWithError() throws {
    XCUIDevice.shared.orientation = .portrait
  }

  func testSettingsHierarchyAndAppearanceResetConfirmation() {
    let app = launch(screen: "root")
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    capture(app, "Settings grouped by intent")
    let appearance = app.buttons["Appearance"].firstMatch
    reveal(appearance, in: app)
    appearance.tap()
    XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    capture(app, "Appearance controls")
    let reset = app.buttons["Reset Appearance…"].firstMatch
    reveal(reset, in: app)
    reset.tap()
    XCTAssertTrue(app.buttons["Reset Appearance"].waitForExistence(timeout: 3))
    capture(app, "Appearance reset confirmation and scope")
    app.buttons["Cancel"].tap()
    XCTAssertFalse(app.buttons["Reset Appearance"].exists)
  }

  func testAccessibilityLargeTextAndLandscape() {
    let app = launch(screen: "accessibility", extra: ["--settings-large-text", "--settings-dark"])
    XCTAssertTrue(app.navigationBars["Accessibility"].waitForExistence(timeout: 10))
    capture(app, "Accessibility large text dark")
    let dynamicType = app.switches["Dynamic Type"].firstMatch
    reveal(dynamicType, in: app)
    capture(app, "Accessibility Dynamic Type large text")
    XCTAssertFalse(app.sliders["Long Press Duration"].exists)
    XCTAssertFalse(app.switches["Shake to Undo"].exists)
    XCUIDevice.shared.orientation = .landscapeLeft
    capture(app, "Accessibility large text landscape")
  }

  func testContentPreferencesUnavailableHaveRetry() {
    let app = launch(screen: "content", extra: ["--settings-server-unavailable"])
    XCTAssertTrue(app.navigationBars["Content & Media"].waitForExistence(timeout: 10))
    capture(app, "Content and media local controls")
    let retry = app.buttons["Retry Loading Preferences"].firstMatch
    reveal(retry, in: app)
    capture(app, "Content server preferences unavailable")
    retry.tap()
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    XCTAssertFalse(app.switches["Scan Sensitive Content"].exists)
  }

  func testSupportCopyAndLargeText() {
    let app = launch(screen: "about", extra: ["--settings-large-text"])
    XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10))
    let copy = app.staticTexts["Leave an optional tip to support Catbird's development."].firstMatch
    reveal(copy, in: app)
    capture(app, "Support Catbird large text")
    XCTAssertFalse(app.buttons["Manage Subscriptions"].exists)
    XCTAssertFalse(app.staticTexts["These do not unlock features"].exists)
  }

  func testSupportUnavailableCanRetry() {
    let app = launch(screen: "about", extra: ["--settings-support-retry"])
    XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10))
    let retry = app.buttons["SupportProductsRetry"].firstMatch
    reveal(retry, in: app)
    capture(app, "Support products unavailable with retry")
    retry.tap()
    let smallTip = app.buttons["SupportTip.blue.catbird.support.onetime.small"].firstMatch
    XCTAssertTrue(smallTip.waitForExistence(timeout: 5))
    capture(app, "Support products loaded after retry")
  }

  private func launch(screen: String, extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--settings-ui-fixture", "--settings-screen=\(screen)"] + extra
    app.launch()
    return app
  }

  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(element.exists && element.isHittable, "Expected a reachable control: \(element)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
