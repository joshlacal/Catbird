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
    let app = launch(screen: "root", extra: ["--settings-appearance-custom"])
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    capture(app, "Settings grouped by intent")
    let appearance = app.buttons["Appearance"].firstMatch
    reveal(appearance, in: app)
    appearance.tap()
    XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    capture(app, "Appearance controls")
    let reset = app.buttons["Reset Appearance…"].firstMatch
    reveal(reset, in: app)
    XCTAssertTrue(app.staticTexts["Current Theme: Dark (Dim)"].exists)
    reset.tap()
    XCTAssertTrue(app.buttons["Reset Appearance"].waitForExistence(timeout: 3))
    capture(app, "Appearance reset confirmation and scope")
    let cancel = app.buttons["Cancel"].firstMatch
    if cancel.waitForExistence(timeout: 1) {
      cancel.tap()
    } else {
      // iOS 27 presents a popover which omits Cancel and dismisses outside its bounds.
      // The right screen edge is outside the captured popover and the Form controls.
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    }
    let dismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.buttons["Reset Appearance"].firstMatch
    )
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
    XCTAssertTrue(app.staticTexts["Current Theme: Dark (Dim)"].exists,
      "Dismissing the confirmation must preserve the selected theme")
    capture(app, "Appearance reset dismissed without changing the theme")
  }

  func testAccessibilityLargeTextAndLandscape() {
    let app = launch(screen: "accessibility", extra: ["--settings-large-text", "--settings-dark"])
    XCTAssertTrue(app.navigationBars["Accessibility"].waitForExistence(timeout: 10))
    capture(app, "Accessibility large text dark")
    let dynamicType = app.switches["Dynamic Type"].firstMatch
    reveal(dynamicType, in: app)
    let maximum = app.buttons["MaximumTextSizePicker"].firstMatch
    reveal(maximum, in: app)
    XCTAssertEqual(maximum.value as? String, "Accessibility Extra Extra Extra Large")
    capture(app, "Accessibility Dynamic Type large text")
    XCUIDevice.shared.orientation = .landscapeLeft
    var previousFrames: [CGRect] = []
    var stableReadings = 0
    let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let window = app.windows.firstMatch.frame
      let form = app.collectionViews.firstMatch.frame
      let navigation = app.navigationBars["Accessibility"].frame
      let frames = [window, form, navigation]
      let laidOut = window.width > window.height && form.width > form.height
        && frames.dropFirst().allSatisfy {
          $0.minX >= window.minX - 1 && $0.maxX <= window.maxX + 1
            && $0.minY >= window.minY - 1 && $0.maxY <= window.maxY + 1
        }
      stableReadings = laidOut && frames == previousFrames ? stableReadings + 1 : 0
      previousFrames = frames
      return stableReadings >= 2
    }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
    let geometry = XCTAttachment(string: "window=\(app.windows.firstMatch.frame); form=\(app.collectionViews.firstMatch.frame); navigation=\(app.navigationBars["Accessibility"].frame)")
    geometry.name = "Accessibility receiving geometry after settled rotation"
    geometry.lifetime = .keepAlways
    add(geometry)
    capture(app, "Accessibility large text landscape")
  }

  func testUnauthenticatedContentPreferencesExposeRetry() {
    let app = launch(screen: "content", extra: ["--settings-server-unavailable"])
    XCTAssertTrue(app.navigationBars["Content & Media"].waitForExistence(timeout: 10))
    capture(app, "Content and media local controls")
    let retry = app.buttons["Retry Loading Preferences"].firstMatch
    reveal(retry, in: app)
    XCTAssertTrue(retry.isEnabled)
    capture(app, "Content server preferences unavailable")
    // This unauthenticated fixture cannot recover a server request. This journey
    // verifies error/retry presentation; it does not claim a successful remote retry.
  }

  func testSupportCopyAndLargeText() {
    let app = launch(screen: "about", extra: ["--settings-large-text"])
    XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10))
    let copy = app.staticTexts.matching(NSPredicate(
      format: "label BEGINSWITH %@", "Leave an optional tip to support Catbird's development."
    )).firstMatch
    reveal(copy, in: app)
    capture(app, "Support Catbird large text")
    let tips = [
      ("small", "Small Support", "$4.99"),
      ("medium", "Medium Support", "$9.99"),
      ("large", "Large Support", "$19.99"),
      ("extralarge", "Extra Large Support", "$49.99")
    ]
    for (identifier, name, price) in tips {
      let tip = app.buttons["SupportTip.blue.catbird.support.onetime.\(identifier)"].firstMatch
      reveal(tip, in: app)
      XCTAssertTrue(tip.label.contains(name) && tip.label.contains(price))
      let window = app.windows.firstMatch.frame
      XCTAssertGreaterThanOrEqual(tip.frame.minX, window.minX - 1)
      XCTAssertLessThanOrEqual(tip.frame.maxX, window.maxX + 1)
      capture(app, "Support \(identifier) label and price at large text")
    }
  }

  func testRemovedControlsAreAbsentThroughoutForms() {
    for screen in ["accessibility", "content", "about"] {
      let app = launch(screen: screen)
      let title = ["accessibility": "Accessibility", "content": "Content & Media", "about": "About"][screen]!
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
      let endMarker = [
        "accessibility": "Adult content and label filtering are managed in Moderation. Video autoplay is managed in Content & Media.",
        "content": "External Media Preferences",
        "about": "Build"
      ][screen]!
      var reachedFinalSection = false
      // Native Form rows are lazy. Check each viewport while traversing the complete form,
      // instead of treating a missing offscreen accessibility node as evidence of removal.
      for _ in 0..<16 {
        let marker = app.staticTexts[endMarker].firstMatch
        reachedFinalSection = reachedFinalSection || (marker.exists && marker.isHittable)
        XCTAssertFalse(app.sliders["Long Press Duration"].exists)
        XCTAssertFalse(app.switches["Shake to Undo"].exists)
        XCTAssertFalse(app.switches["Scan for Sensitive Content"].exists)
        XCTAssertFalse(app.buttons["Manage Subscription"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
          format: "label CONTAINS %@", "These do not unlock features"
        )).firstMatch.exists)
        app.swipeUp()
      }
      XCTAssertTrue(reachedFinalSection, "The traversal must reach the final settings section")
      capture(app, "\(title) end of removed-control traversal")
      app.terminate()
    }
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

  func testUnavailableLocalSettingsRetryEnablesControls() {
    let app = launch(screen: "accessibility", extra: ["--settings-storage-unavailable"])
    let retry = app.buttons["SettingsPersistenceRetry"].firstMatch
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    let altText = app.switches["Require Alt Text Before Posting"].firstMatch
    XCTAssertTrue(altText.exists)
    XCTAssertFalse(altText.isEnabled)
    capture(app, "Local settings unavailable and dependent controls disabled")
    retry.tap()
    waitUntilEnabled(altText)
    XCTAssertEqual(altText.value as? String, "0")
    capture(app, "Local settings recovered without resetting saved values")
  }

  func testUnavailableLocalSettingsKeepsSupportNavigation() {
    let app = launch(screen: "root", extra: ["--settings-storage-unavailable"])
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    let about = app.buttons["About & Support"].firstMatch
    reveal(about, in: app)
    XCTAssertTrue(about.isEnabled)
    about.tap()
    XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
    // Navigation is independent of local preference storage; no tip action is selected.
    capture(app, "Support remains accessible when local settings cannot load")
  }

  func testFailedLocalSaveCanRetryTheAttemptedValue() {
    let app = launch(screen: "accessibility", extra: ["--settings-save-failure"])
    let altText = app.switches["Require Alt Text Before Posting"].firstMatch
    XCTAssertTrue(altText.waitForExistence(timeout: 10))
    waitUntilEnabled(altText)
    // SwiftUI exposes a labeled row-sized switch containing the native UISwitch.
    // The row's center is over its label; tap the native child to exercise the edit.
    let control = altText.descendants(matching: .switch).firstMatch
    XCTAssertTrue(control.exists && control.isHittable)
    control.tap()
    let retry = app.buttons["SettingsPersistenceRetry"].firstMatch
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    XCTAssertEqual(altText.value as? String, "0")
    XCTAssertFalse(altText.isEnabled)
    let pending = app.staticTexts["SettingsPersistencePendingChanges"].firstMatch
    reveal(pending, in: app)
    XCTAssertTrue(pending.label.contains("Require Alt Text: On"))
    capture(app, "Local settings save failed with saved value active and attempted value retained")
    retry.tap()
    waitUntilEnabled(altText)
    XCTAssertEqual(altText.value as? String, "1")
    capture(app, "Local settings retry saved the attempted value")
  }

  private func waitUntilEnabled(_ element: XCUIElement) {
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
  }

  private func launch(screen: String, extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--settings-ui-fixture", "--settings-screen=\(screen)"] + extra
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName",
      extra.contains("--settings-large-text") ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"
    ]
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
