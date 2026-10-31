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
    selectMaximumTextSize("Accessibility Large", picker: maximum, in: app)
    capture(app, "Maximum Text Size selection updates its full value")
    selectMaximumTextSize("Accessibility Extra Extra Extra Large", picker: maximum, in: app)
    revealMaximumTextSizePicker(maximum, in: app)
    XCTAssertEqual(maximum.value as? String, "Accessibility Extra Extra Extra Large")
    capture(app, "Maximum Text Size largest selection fully visible before rotation")
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
    let fullScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    fullScreen.name = "Accessibility-large-text-landscape-full-screen-comparison"
    fullScreen.lifetime = .keepAlways
    add(fullScreen)
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
    XCTAssertTrue(app.navigationBars["About & Support"].waitForExistence(timeout: 10))
    let copy = app.staticTexts.matching(NSPredicate(
      format: "label BEGINSWITH %@", "Leave an optional tip to support Catbird’s development."
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
      let title = ["accessibility": "Accessibility", "content": "Content & Media", "about": "About & Support"][screen]!
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
      let endMarker = [
        "accessibility": "Adult content and label filtering are managed in Moderation. Video autoplay is managed in Content & Media.",
        "content": "External Media Preferences",
        "about": "Version"
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
    XCTAssertTrue(app.navigationBars["About & Support"].waitForExistence(timeout: 10))
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
    XCTAssertTrue(app.navigationBars["About & Support"].waitForExistence(timeout: 5))
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

private extension SettingsSupportJourneyTests {
  func selectMaximumTextSize(_ name: String, picker: XCUIElement, in app: XCUIApplication) {
    picker.tap()
    let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      self.maximumTextSizeMenu(in: app) != nil
    }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 3), .completed)

    for attempt in 0..<8 {
      guard let menu = maximumTextSizeMenu(in: app) else {
        XCTFail("The Maximum Text Size menu disappeared before selecting \(name)")
        return
      }
      let viewport = maximumTextSizeMenuViewport(menu, in: app)
      guard !viewport.isNull, !viewport.isEmpty else {
        XCTFail("The Maximum Text Size menu has no visible receiving viewport")
        return
      }
      let choice = menu.buttons[name].firstMatch
      let choiceFrame = choice.exists ? choice.frame : .null
      let geometry = XCTAttachment(string: "menu=\(menu.frame); viewport=\(viewport); choice=\(name); frame=\(choiceFrame)")
      geometry.name = "Maximum Text Size menu geometry \(name) step \(attempt)"
      geometry.lifetime = .keepAlways
      add(geometry)
      capture(app, "Maximum Text Size open menu \(name) step \(attempt)")

      if choice.exists && choice.isHittable && fullyContains(choice.frame, in: viewport) {
        choice.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
          self.maximumTextSizeMenu(in: app) == nil
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
        let changed = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", name), object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        return
      }
      if attempt < 7 {
        dragWithin(menu, viewport: viewport, upward: !choice.exists || choice.frame.maxY > viewport.maxY)
      }
    }
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Maximum Text Size menu traversal exhausted"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    XCTFail("Expected the complete \(name) option inside the visible menu after bounded scrolling")
  }

  func maximumTextSizeMenu(in app: XCUIApplication) -> XCUIElement? {
    let names = [
      "Extra Extra Large", "Extra Extra Extra Large", "Accessibility Medium", "Accessibility Large",
      "Accessibility Extra Large", "Accessibility Extra Extra Large", "Accessibility Extra Extra Extra Large"
    ]
    return app.collectionViews.allElementsBoundByIndex.first { collection in
      collection.buttons.matching(NSPredicate(format: "label IN %@", names)).count > 0
    }
  }

  func maximumTextSizeMenuViewport(_ menu: XCUIElement, in app: XCUIApplication) -> CGRect {
    var viewport = app.windows.firstMatch.frame.intersection(menu.frame)
    let anchor = menu.buttons.firstMatch
    guard anchor.exists else { return .null }
    // Native menu collections can extend beyond their clipping containers. Only
    // enclosing containers with a collection are relevant; row wrappers are not.
    let containers = app.otherElements.containing(.button, identifier: anchor.label).allElementsBoundByIndex
    var foundContainer = false
    for container in containers where container.collectionViews.count > 0 {
      let bounds = container.frame
      if !bounds.isEmpty {
        foundContainer = true
        viewport = viewport.intersection(bounds)
      }
    }
    return foundContainer ? viewport : .null
  }

  func revealMaximumTextSizePicker(_ picker: XCUIElement, in app: XCUIApplication) {
    for attempt in 0..<8 {
      let form = app.collectionViews.firstMatch
      var viewport = app.windows.firstMatch.frame.intersection(form.frame)
      let top = max(viewport.minY, app.navigationBars["Accessibility"].frame.maxY)
      viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: viewport.maxY - top)
      if picker.exists && picker.isHittable && fullyContains(picker.frame, in: viewport) { return }
      if attempt < 7 {
        dragWithin(form, viewport: viewport, upward: !picker.exists || picker.frame.maxY > viewport.maxY)
      }
    }
    XCTFail("Expected the full closed Maximum Text Size selection to be visible before rotation")
  }

  func fullyContains(_ frame: CGRect, in viewport: CGRect) -> Bool {
    !frame.isNull && !frame.isEmpty && viewport.insetBy(dx: -1, dy: -1).contains(frame)
  }

  func dragWithin(_ element: XCUIElement, viewport: CGRect, upward: Bool) {
    let bounds = element.frame
    let upperY = viewport.minY + viewport.height * 0.25
    let lowerY = viewport.maxY - viewport.height * 0.25
    let origin = element.coordinate(withNormalizedOffset: .zero)
    let upper = origin.withOffset(CGVector(dx: viewport.midX - bounds.minX, dy: upperY - bounds.minY))
    let lower = origin.withOffset(CGVector(dx: viewport.midX - bounds.minX, dy: lowerY - bounds.minY))
    if upward {
      lower.press(forDuration: 0.05, thenDragTo: upper)
    } else {
      upper.press(forDuration: 0.05, thenDragTo: lower)
    }
  }
}
