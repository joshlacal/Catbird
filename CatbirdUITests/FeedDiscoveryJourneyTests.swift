import XCTest

/// Entry and presentation coverage using the existing authenticated account fixture.
/// The fixture does not stub discovery or preference transport, so these tests
/// deliberately make no assertions about network results or successful saves.
final class FeedDiscoveryJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testNormalModeEntryProvidesNativeSearchAndCanClose() {
    let app = XCUIApplication()
    app.launchArguments = ["--e2e-mode", "--run-id=feed-discovery-entry", "--e2e-fixture-account"]
    app.launch()

    let identifiedHome = app.buttons["tab_home"].firstMatch
    let home = identifiedHome.exists ? identifiedHome : app.buttons["Home"].firstMatch
    XCTAssertTrue(home.waitForExistence(timeout: 10))
    home.tap()
    let selector = app.buttons["Feed selector"].firstMatch
    XCTAssertTrue(selector.waitForExistence(timeout: 5))
    selector.tap()

    // No Edit action precedes this: Add Feed must be available in normal mode.
    let addFeed = app.buttons["Add Feed"].firstMatch
    XCTAssertTrue(addFeed.waitForExistence(timeout: 5))
    let feedsScreenshot = XCTAttachment(screenshot: app.screenshot())
    feedsScreenshot.name = "Feeds normal mode"
    feedsScreenshot.lifetime = .keepAlways
    add(feedsScreenshot)
    addFeed.tap()
    let discovery = app.navigationBars["Discover Feeds"]
    XCTAssertTrue(discovery.waitForExistence(timeout: 5))
    XCTAssertTrue(app.searchFields["Search feeds"].waitForExistence(timeout: 5))

    let discoveryScreenshot = XCTAttachment(screenshot: app.screenshot())
    discoveryScreenshot.name = "Discovery native search"
    discoveryScreenshot.lifetime = .keepAlways
    add(discoveryScreenshot)

    discovery.buttons["Close"].tap()
    let dismissed = NSPredicate(format: "exists == false")
    expectation(for: dismissed, evaluatedWith: discovery)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(addFeed.waitForExistence(timeout: 5))
  }
}
