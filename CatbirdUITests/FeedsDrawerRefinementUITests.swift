import XCTest

/// Uses the production Home drawer and its Add Feed sheet. The existing account
/// fixture supplies navigation; discovery still uses its real public transport.
/// This observation never adds, removes, pins, likes or opens a discovered feed.
final class FeedsDrawerRefinementUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testDrawerAndDiscoveryTrailingControls() throws {
    let app = XCUIApplication()
    let rtl = ProcessInfo.processInfo.environment["CATBIRD_FEEDS_RTL"] == "1"
    app.launchArguments = ["--e2e-mode", "--e2e-fixture-account", "--run-id=feeds-drawer-refinement"]
    if rtl { app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar"] }
    app.launch()

    let identifiedHome = app.buttons["tab_home"].firstMatch
    let home = identifiedHome.exists ? identifiedHome : app.buttons["Home"].firstMatch
    XCTAssertTrue(home.waitForExistence(timeout: 10))
    home.tap()
    let selector = app.buttons["Feed selector"].firstMatch
    XCTAssertTrue(selector.waitForExistence(timeout: 5))
    selector.tap()
    let addFeed = app.buttons["Add Feed"].firstMatch
    XCTAssertTrue(addFeed.waitForExistence(timeout: 5))
    capture("Production Feeds drawer", app: app)
    addFeed.tap()
    XCTAssertTrue(app.navigationBars["Discover Feeds"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.searchFields["Search feeds"].waitForExistence(timeout: 5))

    let preview = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "feed.discovery.preview.")
    ).firstMatch
    guard preview.waitForExistence(timeout: 15) else {
      capture("Discovery transport unavailable", app: app)
      throw XCTSkip("No discovery card arrived from public transport; trailing geometry is unverified.")
    }
    let uri = String(preview.identifier.dropFirst("feed.discovery.preview.".count))
    let addControl = app.buttons["feed.library.add.\(uri)"]
    let manageControl = app.buttons["feed.library.manage.\(uri)"]
    let control = addControl.exists ? addControl : manageControl
    XCTAssertTrue(control.waitForExistence(timeout: 5))
    XCTAssertTrue(control.isHittable)
    XCTAssertGreaterThanOrEqual(control.frame.width, 44)
    XCTAssertGreaterThanOrEqual(control.frame.height, 44)
    if rtl {
      XCTAssertLessThanOrEqual(control.frame.maxX, preview.frame.minX + 1)
    } else {
      XCTAssertGreaterThanOrEqual(control.frame.minX, preview.frame.maxX - 1)
    }
    XCTAssertLessThan(control.frame.minY, preview.frame.maxY)
    XCTAssertFalse(control.label.isEmpty)
    capture("Production Discover Feeds trailing control", app: app)
  }

  private func capture(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "\(name) accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }
}
