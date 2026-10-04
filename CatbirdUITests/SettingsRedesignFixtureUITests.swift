import CoreGraphics
import Foundation
import UIKit
import XCTest

/// Source-compatible with Root-accepted Settings. Compilation, exact compiled
/// identifiers and rendered controls require Root's later native qualification.
@MainActor
final class SettingsRedesignFixtureUITests: XCTestCase {
  private let categories: [(id: String, title: String)] = [
    ("accountSecurity", "Account & Security"), ("privacyInteractions", "Privacy & Interactions"),
    ("notifications", "Notifications"), ("feedsDiscovery", "Feeds & Discovery"),
    ("moderation", "Moderation"), ("mediaLinks", "Media & Links"), ("language", "Language"),
    ("appearance", "Appearance"), ("accessibility", "Accessibility"),
    ("helpAbout", "Help & About"), ("advanced", "Advanced")
  ]
  private let textOptions: [(raw: String, title: String)] = [
    ("system", "Full System Range"), ("xxLarge", "Extra Extra Large"),
    ("xxxLarge", "Extra Extra Extra Large"), ("accessibility1", "Accessibility Medium"),
    ("accessibility2", "Accessibility Large"), ("accessibility3", "Accessibility Extra Large"),
    ("accessibility4", "Accessibility Extra Extra Large"),
    ("accessibility5", "Accessibility Extra Extra Extra Large")]
  private var textChoices: [String] { textOptions.map(\.title) }

  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }
  override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

  func testElevenCategoryRowsAndSearchDestinationsKeepNativeContext() throws {
    let app = try launch()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
    XCTAssertEqual(try sample(app).nativeWindowStyle, 1)
    try capture("settings-01-light-root-top", app, witnesses: [
      ("account category", app.buttons["settings.category.accountSecurity"].firstMatch),
      ("privacy category", app.buttons["settings.category.privacyInteractions"].firstMatch)])
    for category in categories {
      let row = app.buttons["settings.category." + category.id].firstMatch
      try reveal(row, app)
      assertHitGeometry(row, app)
      XCTAssertTrue(row.label.contains(category.title))
    }
    try capture("settings-02-light-root-last-group", app, witnesses: [
      ("help category", app.buttons["settings.category.helpAbout"].firstMatch),
      ("advanced category", app.buttons["settings.category.advanced"].firstMatch)])

    for (index, category) in categories.enumerated() {
      let search = try enterSearch(category.title, app)
      let result = app.buttons["settings.result." + category.id].firstMatch
      XCTAssertTrue(result.waitForExistence(timeout: 5))
      try reveal(result, app)
      assertHitGeometry(result, app)
      XCTAssertTrue(result.label.contains(category.title))
      XCTAssertTrue(result.label.contains("Settings"), "Search result must retain its location context")
      try capture("settings-\(String(format: "%02d", 3 + index * 2))-\(category.id)-search-result", app,
        witnesses: [("search query", search), ("category result", result)])
      result.tap()
      XCTAssertTrue(app.navigationBars[category.title].waitForExistence(timeout: 5))
      let state = try sample(app)
      assertIsolation(state)
      try capture("settings-\(String(format: "%02d", 4 + index * 2))-\(category.id)-destination", app,
        witnesses: [("category destination", app.navigationBars[category.title].firstMatch),
          ("return control", app.navigationBars[category.title].buttons.firstMatch)])
      let back = app.navigationBars[category.title].buttons.firstMatch
      XCTAssertTrue(back.isHittable)
      back.tap()
      // Returning to active native search can hide the root title bar. Require
      // the real root search controls, not a hidden destination's retained tree.
      let returnedSearch = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        guard !app.navigationBars[category.title].exists,
          result.exists && result.isHittable, search.exists && search.isHittable else { return false }
        return (search.value as? String) == category.title
          && result.label.contains(category.title) && result.label.contains("Settings")
          && self.receivingViewport(app).insetBy(dx: -1, dy: -1).contains(result.frame)
          && app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(search.frame)
      }, object: app)
      XCTAssertEqual(XCTWaiter.wait(for: [returnedSearch], timeout: 5), .completed,
        "Native Back must restore the actual root search context")
      XCTAssertTrue(result.label.contains(category.title))
      XCTAssertTrue(result.label.contains("Settings"), "Returning must retain the result's location context")
      assertHitGeometry(result, app)
      XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(search.frame),
        "Returning search field must fit the native window")
      XCTAssertEqual(search.value as? String, category.title, "Returning must preserve the actual query")
    }

    app.terminate()
    let dark = try launch(extra: ["--settings-dark"])
    XCTAssertEqual(try sample(dark).nativeWindowStyle, 2)
    try capture("settings-25-dark-root-top", dark, witnesses: [
      ("account category", dark.buttons["settings.category.accountSecurity"].firstMatch),
      ("privacy category", dark.buttons["settings.category.privacyInteractions"].firstMatch)])
    try reveal(dark.buttons["settings.category.advanced"].firstMatch, dark)
    try capture("settings-26-dark-root-last-group", dark, witnesses: [
      ("help category", dark.buttons["settings.category.helpAbout"].firstMatch),
      ("advanced category", dark.buttons["settings.category.advanced"].firstMatch)])
    // Colored SF Symbols and full text are pixel-review oracles; their presence
    // in an AX row does not establish the rendered tint or glyph completeness.
  }

  func testLocalStoreUnavailableRecoversConfirmedValuesAndSearchNavigation() throws {
    let app = try launch(extra: ["--settings-storage-unavailable"])
    let failed = try waitSample(app) { $0.persistenceState == "unavailable" && !$0.canEditLocalSettings }
    XCTAssertEqual(failed.localFetchCalls, 1)
    try capture("settings-27-local-store-unavailable-root", app, witnesses: [
      ("local retry", app.buttons["SettingsPersistenceRetry"].firstMatch),
      ("search query", app.searchFields["Search settings"].firstMatch)])
    _ = try enterSearch("autoplay", app)
    let result = app.buttons["settings.result.media.autoplayVideos"].firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    result.tap()
    XCTAssertTrue(app.navigationBars["Media & Links"].waitForExistence(timeout: 5))
    let autoplay = app.switches["media.autoplayVideos"].firstMatch
    try reveal(autoplay, app)
    XCTAssertFalse(autoplay.isEnabled)
    try capture("settings-28-unavailable-local-control-stays-disabled", app, witnesses: [
      ("autoplay control", autoplay), ("local retry", app.buttons["SettingsPersistenceRetry"].firstMatch)])
    let retry = app.buttons["SettingsPersistenceRetry"].firstMatch
    try reveal(retry, app, upward: false)
    XCTAssertTrue(retry.isEnabled)
    retry.tap()
    let recovered = try waitSample(app) { $0.persistenceState == "ready" && $0.canEditLocalSettings }
    XCTAssertEqual(recovered.localFetchCalls, failed.localFetchCalls + 1)
    XCTAssertEqual(recovered.localSaveCalls, 0)
    let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: autoplay)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    XCTAssertEqual(autoplay.value as? String, "1", "Retry loads the seeded confirmed value")
    assertIsolation(recovered)
    try capture("settings-29-local-retry-loads-confirmed-value", app,
      witnesses: [("autoplay control", autoplay), ("local retry", retry)])
  }

  func testFeedPreferenceRetryIsRejectedWithoutAuthenticatedOwnership() throws {
    // This actual production-configured editor rejects before read; remote
    // read failure/recovery requires separate admitted component/service proof.
    let app = try launch(screen: "feedFiltering", extra: ["--settings-server-unavailable"])
    XCTAssertTrue(app.navigationBars["Feed Filtering"].waitForExistence(timeout: 8))
    let retry = app.buttons["Retry Loading"].firstMatch
    try reveal(retry, app)
    XCTAssertTrue(retry.isEnabled)
    let remote = app.switches["feed.replies"].firstMatch
    XCTAssertTrue(!remote.exists || !remote.isEnabled, "Unknown remote values must not be editable")
    let before = try waitSample(app) { $0.feedLoad.finishedAttempts >= 1 }
    XCTAssertNotNil(UUID(uuidString: before.feedLoad.editorID))
    XCTAssertEqual(before.feedLoad.sceneID, before.sceneID)
    XCTAssertFalse(before.feedLoad.editorChanged)
    XCTAssertEqual(before.feedLoad.entries, 1)
    XCTAssertEqual(before.feedLoad.refusals, 1)
    XCTAssertEqual(before.feedLoad.notCurrentAccountRefusals, 1)
    XCTAssertEqual(before.feedLoad.readEntries, 0)
    XCTAssertEqual(before.feedLoad.finishedAttempts, 1)
    XCTAssertEqual(before.feedLoad.lastEnteredAttempt, 1)
    XCTAssertEqual(before.feedLoad.lastRefusedAttempt, 1)
    XCTAssertEqual(before.feedLoad.lastFinishedAttempt, 1)
    XCTAssertEqual(before.feedLoad.lastRefusalReason, "notCurrentAccount")
    XCTAssertEqual(before.feedLoad.lastFinishedRefusalReason, "notCurrentAccount")
    assertIsolation(before)
    try capture("settings-30-opening-feed-account-refusal", app,
      witnesses: [("feed retry", retry), ("unconfirmed feed control", remote)])
    retry.tap()
    let after = try waitSample(app) { $0.feedLoad.finishedAttempts > before.feedLoad.finishedAttempts }
    XCTAssertEqual(after.feedLoad.editorID, before.feedLoad.editorID)
    XCTAssertEqual(after.feedLoad.sceneID, before.feedLoad.sceneID)
    XCTAssertEqual(after.sceneID, before.sceneID)
    XCTAssertFalse(after.feedLoad.editorChanged)
    XCTAssertEqual(after.feedLoad.entries, before.feedLoad.entries + 1)
    XCTAssertEqual(after.feedLoad.refusals, before.feedLoad.refusals + 1)
    XCTAssertEqual(after.feedLoad.notCurrentAccountRefusals, before.feedLoad.notCurrentAccountRefusals + 1)
    XCTAssertEqual(after.feedLoad.finishedAttempts, before.feedLoad.finishedAttempts + 1)
    XCTAssertEqual(after.feedLoad.lastEnteredAttempt, before.feedLoad.lastEnteredAttempt + 1)
    XCTAssertEqual(after.feedLoad.lastRefusedAttempt, after.feedLoad.lastEnteredAttempt)
    XCTAssertEqual(after.feedLoad.lastFinishedAttempt, after.feedLoad.lastEnteredAttempt)
    XCTAssertEqual(after.feedLoad.lastRefusalReason, "notCurrentAccount")
    XCTAssertEqual(after.feedLoad.lastFinishedRefusalReason, "notCurrentAccount")
    XCTAssertEqual(after.feedLoad.readEntries, 0)
    XCTAssertTrue(retry.isEnabled)
    XCTAssertTrue(!remote.exists || !remote.isEnabled)
    XCTAssertEqual(before.localSaveCalls, 0)
    XCTAssertEqual(after.localSaveCalls, before.localSaveCalls)
    XCTAssertEqual(after.localFetchCalls, before.localFetchCalls)
    XCTAssertEqual(after.transport.refusedRequests, before.transport.refusedRequests,
      "Account refusal occurs before the editor's read; HTTP is not the Retry oracle")
    assertIsolation(after)
    try capture("settings-31-single-feed-retry-account-refusal", app,
      witnesses: [("feed retry", retry), ("unconfirmed feed control", remote)])
  }

  func testFullMaximumTextSizeChoicesUseActualCategoryAcrossRotation() throws {
    let app = try launch(screen: "textReadability", extra: ["--settings-large-text", "--settings-dark"])
    XCTAssertTrue(app.navigationBars["Text & Readability"].waitForExistence(timeout: 8))
    let native = try sample(app)
    XCTAssertEqual(native.systemTextCategory, UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue)
    XCTAssertEqual(native.fontManagerTextCategory, native.systemTextCategory)
    XCTAssertEqual(native.nativeWindowStyle, 2)
    let picker = app.buttons["text.maxSize"].firstMatch
    try reveal(picker, app)
    XCTAssertEqual(picker.value as? String, textChoices.last)
    try capture("settings-32-native-accessibility-category-and-full-current-cap", app,
      witnesses: [("current text cap", picker)])
    for (index, option) in textOptions.enumerated() {
      let choice = option.title
      try reveal(picker, app)
      picker.tap()
      let menu = try waitMenu(app)
      let button = menu.buttons[choice].firstMatch
      try revealMenuChoice(button, menu: menu, app: app)
      XCTAssertEqual(button.label, choice)
      let checkpoint = option.raw == "system" ? "settings-42-full-system-range-choice"
        : "settings-\(32 + index)-full-text-cap-choice-\(index)"
      try capture(checkpoint, app,
        witnesses: [("text cap choice", button), ("text cap menu", menu), ("current text cap", picker)])
      button.tap()
      let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", choice), object: picker)
      XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
      let confirmed = try waitSample(app) { $0.maxTextSize == option.raw && $0.persistenceState == "ready" }
      XCTAssertEqual(confirmed.systemTextCategory, native.systemTextCategory)
      XCTAssertEqual(confirmed.fontManagerTextCategory, confirmed.systemTextCategory)
      assertIsolation(confirmed)
      if option.raw == "system" {
        try capture("settings-43-full-system-range-confirmed-native-category", app,
          witnesses: [("full system range selected", picker)])
      }
    }
    let saved = try waitSample(app) { $0.maxTextSize == "accessibility5" && $0.persistenceState == "ready" }
    assertIsolation(saved)
    try reveal(picker, app)
    try capture("settings-40-highest-cap-selected-with-full-value", app,
      witnesses: [("highest text cap", picker)])
    XCUIDevice.shared.orientation = .landscapeLeft
    var previous = CGRect.zero
    var stable = 0
    let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let frame = app.windows.firstMatch.frame
      stable = frame.width > frame.height && frame == previous ? stable + 1 : 0
      previous = frame
      return stable >= 2
    }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 8), .completed)
    try reveal(picker, app)
    assertHitGeometry(picker, app)
    XCTAssertEqual(picker.value as? String, textChoices.last)
    let rotated = try sample(app)
    XCTAssertGreaterThan(rotated.nativeWindowWidth, rotated.nativeWindowHeight)
    XCTAssertEqual(rotated.systemTextCategory, native.systemTextCategory)
    XCTAssertEqual(rotated.fontManagerTextCategory, rotated.systemTextCategory)
    try capture("settings-41-landscape-native-window-and-full-cap", app,
      witnesses: [("landscape text cap", picker)])
  }

  private func launch(screen: String = "root", extra: [String] = []) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--settings-ui-fixture", "--settings-screen=" + screen,
      "-defaultComposerLanguage", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-UIPreferredContentSizeCategoryName", extra.contains("--settings-large-text")
        ? UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue : UIContentSizeCategory.large.rawValue] + extra
    app.launch()
    let probe = app.descendants(matching: .any)["settings.fixture.counters"].firstMatch
    XCTAssertTrue(probe.waitForExistence(timeout: 8), "A setup failure cannot be treated as an unavailable destination")
    let value = try waitSample(app) { $0.ready }
    assertIsolation(value)
    XCTAssertEqual(value.systemTextCategory, extra.contains("--settings-large-text")
      ? UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue : UIContentSizeCategory.large.rawValue)
    XCTAssertEqual(value.fontManagerTextCategory, value.systemTextCategory)
    return app
  }

  private func enterSearch(_ query: String, _ app: XCUIApplication) throws -> XCUIElement {
    let field = app.searchFields["Search settings"].firstMatch
    // Search belongs to native navigation chrome, outside the Form viewport.
    // Pull the actual root to reveal it; don't apply a row viewport to this field.
    var reached = false
    for attempt in 0..<12 {
      if field.exists && field.isHittable
        && app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(field.frame) {
        reached = true; break
      }
      if attempt < 11 { app.swipeDown() }
    }
    guard reached else { XCTFail("Native Settings search field is unreachable"); throw FixtureError.controlNotReached }
    field.tap()
    let value = field.value as? String ?? ""
    if !value.isEmpty && value != "Search settings" {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
    field.typeText(query)
    XCTAssertEqual(field.value as? String, query)
    return field
  }

  private func reveal(_ element: XCUIElement, _ app: XCUIApplication, upward: Bool = true) throws {
    for attempt in 0..<24 {
      let viewport = receivingViewport(app)
      if element.exists && element.isHittable && viewport.insetBy(dx: -1, dy: -1).contains(element.frame) { return }
      guard attempt < 23 else { break }
      // Move toward the control's actual position in momentum-free steps, so a
      // fling cannot carry it past the viewport and away from a one-way search.
      var moveContentUp = upward
      if element.exists, !element.frame.isEmpty {
        if element.frame.maxY > viewport.maxY { moveContentUp = true }
        else if element.frame.minY < viewport.minY { moveContentUp = false }
      }
      let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
      let x = viewport.midX
      let lower = viewport.minY + viewport.height * 0.7
      let upper = viewport.minY + viewport.height * 0.3
      origin.withOffset(CGVector(dx: x, dy: moveContentUp ? lower : upper))
        .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: moveContentUp ? upper : lower)),
               withVelocity: .default, thenHoldForDuration: 0.2)
    }
    XCTFail("Expected a fully reachable native control: \(element.identifier)")
    throw FixtureError.controlNotReached
  }
  private func receivingViewport(_ app: XCUIApplication) -> CGRect {
    let window = app.windows.firstMatch.frame
    let form = app.collectionViews.firstMatch
    var viewport = form.exists ? window.intersection(form.frame) : window
    let navigation = app.navigationBars.firstMatch
    var top = viewport.minY
    if navigation.exists { top = max(top, navigation.frame.maxY) }
    var bottom = viewport.maxY
    if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY) }
    // Active native search can replace the bar and sit above the keyboard.
    let search = app.searchFields["Search settings"].firstMatch
    if search.exists && search.isHittable {
      let frame = search.frame
      if frame.midY < viewport.midY { top = max(top, frame.maxY) }
      else { bottom = min(bottom, frame.minY) }
    }
    viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, bottom - top))
    return viewport
  }
  private func assertHitGeometry(_ element: XCUIElement, _ app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.isHittable, file: file, line: line)
    XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
    XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
    XCTAssertTrue(receivingViewport(app).insetBy(dx: -1, dy: -1).contains(element.frame),
      "Actual control frame must fit the unobscured native receiving viewport", file: file, line: line)
  }

  private func waitMenu(_ app: XCUIApplication) throws -> XCUIElement {
    let deadline = Date().addingTimeInterval(4)
    repeat {
      if let menu = app.collectionViews.allElementsBoundByIndex.first(where: {
        $0.buttons.matching(NSPredicate(format: "label IN %@", textChoices)).count > 0
      }) { return menu }
      Thread.sleep(forTimeInterval: 0.08)
    } while Date() < deadline
    XCTFail("Native maximum text-size menu did not appear")
    throw FixtureError.controlNotReached
  }
  private func revealMenuChoice(_ choice: XCUIElement, menu: XCUIElement, app: XCUIApplication) throws {
    for attempt in 0..<8 {
      let viewport = menuViewport(menu, app)
      guard !viewport.isNull && !viewport.isEmpty else { throw FixtureError.controlNotReached }
      if choice.exists && choice.isHittable && viewport.insetBy(dx: -1, dy: -1).contains(choice.frame) { return }
      if attempt < 7 {
        let origin = menu.coordinate(withNormalizedOffset: .zero)
        let upper = origin.withOffset(CGVector(dx: viewport.midX - menu.frame.minX, dy: viewport.minY + viewport.height * 0.25 - menu.frame.minY))
        let lower = origin.withOffset(CGVector(dx: viewport.midX - menu.frame.minX, dy: viewport.maxY - viewport.height * 0.25 - menu.frame.minY))
        if !choice.exists || choice.frame.maxY > viewport.maxY { lower.press(forDuration: 0.05, thenDragTo: upper) }
        else { upper.press(forDuration: 0.05, thenDragTo: lower) }
      }
    }
    XCTFail("The complete text-cap choice is clipped or unreachable")
    throw FixtureError.controlNotReached
  }
  private func menuViewport(_ menu: XCUIElement, _ app: XCUIApplication) -> CGRect {
    var viewport = app.windows.firstMatch.frame.intersection(menu.frame)
    let anchor = menu.buttons.firstMatch
    guard anchor.exists else { return .null }
    var found = false
    for container in app.otherElements.containing(.button, identifier: anchor.label).allElementsBoundByIndex
      where container.collectionViews.count > 0 && !container.frame.isEmpty {
      found = true
      viewport = viewport.intersection(container.frame)
    }
    return found ? viewport : .null
  }

  private func assertIsolation(_ sample: Sample, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(sample.noAuthenticatedHost, file: file, line: line)
    XCTAssertTrue(sample.draftTestingConfigurationApplied && sample.currentDraftAbsent, file: file, line: line)
    XCTAssertTrue(sample.editingDefaultsSuite.hasPrefix("settings.native.fixture."), file: file, line: line)
    XCTAssertEqual(sample.transport.attemptedWrites, 0, file: file, line: line)
    XCTAssertEqual(sample.transport.unexpectedRequests, 0, file: file, line: line)
    XCTAssertEqual(sample.fakeSupportPurchaseAttempts, 0, file: file, line: line)
    XCTAssertTrue(sample.globalOrGroupDefaultsChangedKeys.isEmpty, file: file, line: line)
    XCTAssertFalse(sample.feedLoad.editorChanged, file: file, line: line)
    // Scoped default changes are expected AppSettings behavior within Root's
    // disposable domains; this is not a zero-defaults-write assertion.
  }
  private func sample(_ app: XCUIApplication) throws -> Sample {
    let raw = app.descendants(matching: .any)["settings.fixture.counters"].firstMatch.value as? String
    guard let raw else { throw FixtureError.sampleMissing }
    return try JSONDecoder().decode(Sample.self, from: Data(raw.utf8))
  }
  private func waitSample(_ app: XCUIApplication, _ predicate: (Sample) -> Bool) throws -> Sample {
    let deadline = Date().addingTimeInterval(8)
    repeat {
      if let value = try? sample(app), predicate(value) { return value }
      Thread.sleep(forTimeInterval: 0.08)
    } while Date() < deadline
    XCTFail("Timed out waiting for observed fixture state")
    throw FixtureError.sampleMissing
  }
  private func capture(_ name: String, _ app: XCUIApplication, witnesses: [(String, XCUIElement)]) throws {
    // Keep both original rasters. Geometry and orientation can reject a capture
    // mismatch, but cannot establish complete, readable, nonblack pixels.
    let before = try? waitCaptureGeometry(app)
    let appCaptureTime = ProcessInfo.processInfo.systemUptime
    let appCapture = app.screenshot()
    let screenshot = XCTAttachment(screenshot: appCapture)
    screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    let screenCaptureTime = ProcessInfo.processInfo.systemUptime
    let screenCapture = XCUIScreen.main.screenshot()
    let screen = XCTAttachment(screenshot: screenCapture)
    screen.name = name + " — independent device screen"; screen.lifetime = .keepAlways; add(screen)
    let immediateAfter = try? captureGeometry(app)
    let settledAfter = try? waitCaptureGeometry(app)
    // Resolve only the explicitly named elements. Never construct the full
    // application hierarchy merely to truncate its resulting string.
    let elements: [(String, XCUIElement)] = [
      ("native window", app.windows.firstMatch), ("navigation bar", app.navigationBars.firstMatch),
      ("receiving form", app.collectionViews.firstMatch), ("keyboard", app.keyboards.firstMatch)
    ] + witnesses
    XCTAssertLessThanOrEqual(elements.count, 8, "Capture witnesses must stay finite")
    let records = Array(elements.prefix(8)).map { elementWitness($0.0, $0.1) }
    let payload: [String: Any] = ["checkpoint": name, "elementLimit": 8,
      "identifierLimit": 160, "labelLimit": 512, "valueLimit": 512, "witnesses": records,
      "capture": ["stableSampleRequirement": 2, "settleTimeoutSeconds": 8, "settleSampleLimit": 24,
        "before": before?.record ?? ["error": "stable geometry unavailable"],
        "immediateAfter": immediateAfter?.record ?? ["error": "geometry unavailable"],
        "settledAfter": settledAfter?.record ?? ["error": "stable geometry unavailable"],
        "appCaptureUptime": appCaptureTime, "screenCaptureUptime": screenCaptureTime,
        "appImage": imageEvidence(appCapture), "deviceScreenImage": imageEvidence(screenCapture),
        "interfaceOrientation": "not exposed by the existing fixture probe",
        "pixelAcceptance": "held for visual review; geometry cannot prove complete readable pixels"]]
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    let ax = XCTAttachment(string: data.flatMap { String(data: $0, encoding: .utf8) } ?? "witness serialization failed")
    ax.name = name + " — compact explicit element witnesses"; ax.lifetime = .keepAlways; add(ax)
    let raw = app.descendants(matching: .any)["settings.fixture.counters"].firstMatch.value as? String ?? "missing probe"
    let receipt = XCTAttachment(string: raw + "\nwindow=\(app.windows.firstMatch.frame); receiving=\(receivingViewport(app))")
    receipt.name = name + " — actual state, refused transport and native geometry"
    receipt.lifetime = .keepAlways; add(receipt)
    guard data != nil else {
      XCTFail("Capture orientation/geometry metadata must serialize")
      throw FixtureError.captureUnstable
    }
    guard let before, let immediateAfter, let settledAfter else {
      XCTFail("Capture requires bounded stable native window/probe geometry before and after")
      throw FixtureError.captureUnstable
    }
    XCTAssertEqual(immediateAfter, before, "Geometry/state/orientation changed while capturing")
    XCTAssertEqual(settledAfter, before, "Capture geometry/state/orientation did not remain stable")
    guard let pixels = screenCapture.image.cgImage else {
      XCTFail("Independent screen capture has no CGImage pixel dimensions")
      throw FixtureError.captureUnstable
    }
    let swapsAxes = imageSwapsAxes(screenCapture.image.imageOrientation)
    let displayWidth = Double(swapsAxes ? pixels.height : pixels.width)
    let displayHeight = Double(swapsAxes ? pixels.width : pixels.height)
    XCTAssertEqual(displayWidth / displayHeight, before.probeWidth / before.probeHeight,
      accuracy: 0.01, "Independent screen raster orientation/aspect must match the native window")
  }
  private func captureGeometry(_ app: XCUIApplication) throws -> CaptureGeometry {
    let observed = try sample(app)
    let frame = app.windows.firstMatch.frame
    let orientation = XCUIDevice.shared.orientation
    let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
    let portrait = orientation == .portrait || orientation == .portraitUpsideDown
    guard !frame.isNull && !frame.isEmpty && frame.width.isFinite && frame.height.isFinite,
      observed.nativeWindowWidth.isFinite && observed.nativeWindowHeight.isFinite,
      observed.nativeWindowWidth > 0 && observed.nativeWindowHeight > 0,
      abs(Double(frame.width) - observed.nativeWindowWidth) <= 1,
      abs(Double(frame.height) - observed.nativeWindowHeight) <= 1,
      (landscape && frame.width > frame.height) || (portrait && frame.height > frame.width) else {
      throw FixtureError.captureUnstable
    }
    return CaptureGeometry(window: frame, probeWidth: observed.nativeWindowWidth,
      probeHeight: observed.nativeWindowHeight, deviceOrientation: orientation.rawValue,
      sceneID: observed.sceneID, systemCategory: observed.systemTextCategory,
      fontCategory: observed.fontManagerTextCategory, windowStyle: observed.nativeWindowStyle)
  }
  private func waitCaptureGeometry(_ app: XCUIApplication) throws -> CaptureGeometry {
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    var previous: CaptureGeometry?
    for _ in 0..<24 {
      guard ProcessInfo.processInfo.systemUptime < deadline else { break }
      let current = try? captureGeometry(app)
      if let current, current == previous { return current }
      previous = current
      Thread.sleep(forTimeInterval: 0.08)
    }
    throw FixtureError.captureUnstable
  }
  private func imageSwapsAxes(_ orientation: UIImage.Orientation) -> Bool {
    switch orientation {
    case .left, .right, .leftMirrored, .rightMirrored: return true
    default: return false
    }
  }
  private func imageEvidence(_ screenshot: XCUIScreenshot) -> [String: Any] {
    let image = screenshot.image
    var record: [String: Any] = ["uiImageOrientationRawValue": image.imageOrientation.rawValue,
      "uiImageWidthPoints": Double(image.size.width), "uiImageHeightPoints": Double(image.size.height),
      "uiImageScale": Double(image.scale), "pixelTransformation": "none"]
    if let pixels = image.cgImage {
      let swapsAxes = imageSwapsAxes(image.imageOrientation)
      record["cgImageWidthPixels"] = pixels.width
      record["cgImageHeightPixels"] = pixels.height
      record["declaredDisplayWidthPixels"] = swapsAxes ? pixels.height : pixels.width
      record["declaredDisplayHeightPixels"] = swapsAxes ? pixels.width : pixels.height
    } else { record["error"] = "CGImage unavailable" }
    return record
  }
  private struct CaptureGeometry: Equatable {
    let window: CGRect
    let probeWidth: Double, probeHeight: Double
    let deviceOrientation: Int, sceneID: String, systemCategory: String, fontCategory: String
    let windowStyle: Int
    var record: [String: Any] {
      ["window": ["x": Double(window.minX), "y": Double(window.minY),
        "width": Double(window.width), "height": Double(window.height)],
        "probeWidth": probeWidth, "probeHeight": probeHeight,
        "deviceOrientationRawValue": deviceOrientation, "sceneID": sceneID,
        "systemTextCategory": systemCategory, "fontManagerTextCategory": fontCategory,
        "nativeWindowStyle": windowStyle]
    }
  }
  private func elementWitness(_ role: String, _ element: XCUIElement) -> [String: Any] {
    let exists = element.exists
    var record: [String: Any] = ["role": String(role.prefix(80)), "exists": exists]
    guard exists else { return record }
    let identifier = element.identifier
    let label = element.label
    // Values outside the scalar AX string/number contract are deliberately not
    // expanded via description; the named probe has its own state attachment.
    let value: String
    if let string = element.value as? String { value = string }
    else if let number = element.value as? NSNumber { value = number.stringValue }
    else { value = "<non-scalar or absent>" }
    let frame = element.frame
    record["identifier"] = String(identifier.prefix(160))
    record["identifierTruncated"] = identifier.count > 160
    record["label"] = String(label.prefix(512))
    record["labelTruncated"] = label.count > 512
    record["value"] = String(value.prefix(512))
    record["valueTruncated"] = value.count > 512
    record["enabled"] = element.isEnabled
    record["hittable"] = element.isHittable
    record["frame"] = ["x": Double(frame.minX), "y": Double(frame.minY),
      "width": Double(frame.width), "height": Double(frame.height)]
    return record
  }
  private enum FixtureError: Error { case controlNotReached, sampleMissing, captureUnstable }
  private struct Transport: Decodable { let refusedRequests: Int, attemptedWrites: Int, unexpectedRequests: Int }
  private struct FeedLoad: Decodable {
    let editorID: String, editorChanged: Bool, sceneID: String
    let entries: Int, refusals: Int, notCurrentAccountRefusals: Int, readEntries: Int, finishedAttempts: Int
    let lastEnteredAttempt: UInt64, lastRefusedAttempt: UInt64, lastFinishedAttempt: UInt64
    let lastRefusalReason: String, lastFinishedRefusalReason: String
  }
  private struct Sample: Decodable {
    let ready: Bool, sampleCount: Int, noAuthenticatedHost: Bool
    let draftTestingConfigurationApplied: Bool, currentDraftAbsent: Bool
    let editingDefaultsSuite: String, persistenceState: String, canEditLocalSettings: Bool
    let sceneID: String
    let localFetchCalls: Int, localSaveCalls: Int, fakeSupportPurchaseAttempts: Int
    let maxTextSize: String, globalOrGroupDefaultsChangedKeys: [String]
    let transport: Transport
    let feedLoad: FeedLoad
    let systemTextCategory: String, fontManagerTextCategory: String, nativeWindowStyle: Int
    let nativeWindowWidth: Double, nativeWindowHeight: Double
  }
}
