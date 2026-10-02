import XCTest

/// Offline presentation journeys. These never instantiate an authenticated client
/// and do not claim transport or streamed-video qualification.
final class VideoFeedFixtureUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDownWithError() throws {
    XCUIDevice.shared.orientation = .portrait
  }

  func testActionsAndCommentsHaveDistinctBehavior() {
    let app = launchFixture()
    let like = app.buttons["videoLike"].firstMatch
    let repost = app.buttons["videoRepost"].firstMatch
    XCTAssertTrue(like.waitForExistence(timeout: 8))
    assertControlsFit(app)
    like.tap()
    XCTAssertTrue(like.wait(for: \.label, toEqual: "Unlike. Count: 124", timeout: 4))
    XCTAssertEqual(repost.label, "Repost. Count: 4")
    repost.tap()
    XCTAssertTrue(repost.wait(for: \.label, toEqual: "Undo repost. Count: 5", timeout: 4))
    XCTAssertFalse(app.staticTexts["videoFixtureThread"].exists)
    capture("Vids actions remain on the current page", app: app)
    app.buttons["videoComments"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["videoFixtureThread"].waitForExistence(timeout: 4))
    capture("Comments opens the fixture thread", app: app)
  }

  func testFailurePreservesReactionAndShowsRecoverableError() {
    let app = launchFixture(["--video-fixture-fail-actions"])
    let like = app.buttons["videoLike"].firstMatch
    XCTAssertTrue(like.waitForExistence(timeout: 8))
    like.tap()
    let alert = app.alerts["Action unsuccessful"]
    XCTAssertTrue(alert.waitForExistence(timeout: 4))
    capture("Failed mock reaction", app: app)
    alert.buttons["OK"].tap()
    XCTAssertEqual(like.label, "Like. Count: 123")
    XCTAssertTrue(like.isEnabled)
  }

  func testLargeTextAndRotationKeepControlsReachable() {
    let app = launchFixture(["--video-fixture-accessibility"])
    XCTAssertTrue(app.buttons["videoLike"].firstMatch.waitForExistence(timeout: 8))
    assertControlsFit(app)
    capture("Vids large text portrait", app: app)
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil
    )
    XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 4), .completed)
    assertControlsFit(app)
    XCTAssertTrue(app.staticTexts["videoFixturePage0"].exists)
    capture("Vids large text landscape", app: app)
  }

  func testPlaybackRetryRemainsSeparateFromShortLandscapeFooter() {
    for accessibility in [false, true] {
      XCUIDevice.shared.orientation = .portrait
      assertPlaybackRetryLayout(accessibility: accessibility)
    }
  }

  private func assertPlaybackRetryLayout(accessibility: Bool) {
    let arguments = ["--video-fixture-fail-playback"]
      + (accessibility ? ["--video-fixture-accessibility"] : [])
    let app = launchFixture(arguments)
    let retry = app.buttons["videoPlaybackRetry"].firstMatch
    XCTAssertTrue(retry.waitForExistence(timeout: 8))
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil
    )
    XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 4), .completed)
    assertControlsFit(app)
    XCTAssertTrue(retry.isHittable)
    XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
    XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
    XCTAssertTrue(app.frame.contains(retry.frame))
    for identifier in ["videoFixtureAuthor", "videoLike", "videoRepost", "videoComments", "videoProgress"] {
      let footerControl = app.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(footerControl.exists, identifier)
      XCTAssertFalse(retry.frame.intersects(footerControl.frame), identifier)
    }
    capture("Playback retry above landscape footer, accessibility: \(accessibility)", app: app)
    retry.tap()
    XCTAssertTrue(retry.wait(for: \.exists, toEqual: false, timeout: 4))
    assertControlsFit(app)
    let author = app.descendants(matching: .any)["videoFixtureAuthor"].firstMatch
    XCTAssertTrue(app.frame.contains(author.frame))
    capture("Playback recovered with contained footer, accessibility: \(accessibility)", app: app)
    app.terminate()
  }

  private func launchFixture(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--video-feed-ui-fixture"] + extra
    app.launch()
    return app
  }

  private func assertControlsFit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let viewport = app.frame
    for identifier in ["videoLike", "videoRepost", "videoComments"] {
      let control = app.buttons[identifier].firstMatch
      XCTAssertTrue(control.isHittable, identifier, file: file, line: line)
      XCTAssertGreaterThanOrEqual(control.frame.width, 44, file: file, line: line)
      XCTAssertGreaterThanOrEqual(control.frame.height, 44, file: file, line: line)
      XCTAssertTrue(viewport.contains(control.frame), identifier, file: file, line: line)
    }
    let progress = app.descendants(matching: .any)["videoProgress"].firstMatch
    XCTAssertTrue(progress.exists, file: file, line: line)
    XCTAssertGreaterThanOrEqual(progress.frame.height, 44, file: file, line: line)
    XCTAssertTrue(viewport.contains(progress.frame), file: file, line: line)
    let tabBar = app.tabBars.firstMatch
    if tabBar.exists && tabBar.frame.minY > viewport.midY {
      XCTAssertLessThanOrEqual(progress.frame.maxY, tabBar.frame.minY, file: file, line: line)
    }
  }

  private func capture(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
