import CoreGraphics
import Foundation
import XCTest

/// Source staging against sealed bf6 navigation interfaces. Final feature APIs,
/// exact compiled IDs and rendered controls require Root's later acceptance.
@MainActor
final class SettingsRedesignFixtureUITests: XCTestCase {
  private let categories: [(id: String, title: String)] = [
    ("accountSecurity", "Account & Security"), ("privacyInteractions", "Privacy & Interactions"),
    ("notifications", "Notifications"), ("feedsDiscovery", "Feeds & Discovery"),
    ("moderation", "Moderation"), ("mediaLinks", "Media & Links"), ("language", "Language"),
    ("appearance", "Appearance"), ("accessibility", "Accessibility"),
    ("helpAbout", "Help & About"), ("advanced", "Advanced")
  ]
  private let textChoices = ["Extra Extra Large", "Extra Extra Extra Large", "Accessibility Medium",
    "Accessibility Large", "Accessibility Extra Large", "Accessibility Extra Extra Large",
    "Accessibility Extra Extra Extra Large"]

  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }
  override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

  func testElevenCategoryRowsAndSearchDestinationsKeepNativeContext() throws {
    let app = try launch()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
    XCTAssertEqual(try sample(app).nativeWindowStyle, 1)
    capture("settings-01-light-root-top", app)
    for category in categories {
      let row = app.buttons["settings.category." + category.id].firstMatch
      try reveal(row, app)
      assertHitGeometry(row, app)
      XCTAssertTrue(row.label.contains(category.title))
    }
    capture("settings-02-light-root-last-group", app)

    for (index, category) in categories.enumerated() {
      let search = try enterSearch(category.title, app)
      let result = app.buttons["settings.result." + category.id].firstMatch
      XCTAssertTrue(result.waitForExistence(timeout: 5))
      try reveal(result, app)
      assertHitGeometry(result, app)
      XCTAssertTrue(result.label.contains(category.title))
      XCTAssertTrue(result.label.contains("Settings"), "Search result must retain its location context")
      capture("settings-\(String(format: "%02d", 3 + index * 2))-\(category.id)-search-result", app)
      result.tap()
      XCTAssertTrue(app.navigationBars[category.title].waitForExistence(timeout: 5))
      let state = try sample(app)
      assertIsolation(state)
      capture("settings-\(String(format: "%02d", 4 + index * 2))-\(category.id)-destination", app)
      let back = app.navigationBars[category.title].buttons.firstMatch
      XCTAssertTrue(back.isHittable)
      back.tap()
      XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
      XCTAssertEqual(search.value as? String, category.title, "Returning must preserve the actual query")
    }

    app.terminate()
    let dark = try launch(extra: ["--settings-dark"])
    XCTAssertEqual(try sample(dark).nativeWindowStyle, 2)
    capture("settings-25-dark-root-top", dark)
    try reveal(dark.buttons["settings.category.advanced"].firstMatch, dark)
    capture("settings-26-dark-root-last-group", dark)
    // Colored SF Symbols and full text are pixel-review oracles; their presence
    // in an AX row does not establish the rendered tint or glyph completeness.
  }

  func testLocalStoreUnavailableRecoversConfirmedValuesAndSearchNavigation() throws {
    let app = try launch(extra: ["--settings-storage-unavailable"])
    let failed = try waitSample(app) { $0.persistenceState == "unavailable" && !$0.canEditLocalSettings }
    XCTAssertEqual(failed.localFetchCalls, 1)
    capture("settings-27-local-store-unavailable-root", app)
    _ = try enterSearch("autoplay", app)
    let result = app.buttons["settings.result.media.autoplayVideos"].firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    result.tap()
    XCTAssertTrue(app.navigationBars["Media & Links"].waitForExistence(timeout: 5))
    let autoplay = app.switches["media.autoplayVideos"].firstMatch
    try reveal(autoplay, app)
    XCTAssertFalse(autoplay.isEnabled)
    capture("settings-28-unavailable-local-control-stays-disabled", app)
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
    capture("settings-29-local-retry-loads-confirmed-value", app)
  }

  func testRemoteReadFailureRetryCannotConfirmOrWritePreferences() throws {
    // The canonical destination and retained Retry copy must be checked against
    // accepted final feature source; no legacy-form fallback or runtime skip.
    let app = try launch(screen: "feedFiltering", extra: ["--settings-server-unavailable"])
    XCTAssertTrue(app.navigationBars["Feed Filtering"].waitForExistence(timeout: 8))
    let retry = app.buttons["Retry Loading Preferences"].firstMatch
    try reveal(retry, app)
    XCTAssertTrue(retry.isEnabled)
    let remote = app.switches["feed.replies"].firstMatch
    XCTAssertTrue(!remote.exists || !remote.isEnabled, "Unknown remote values must not be editable")
    let before = try sample(app)
    assertIsolation(before)
    capture("settings-30-remote-values-unconfirmed-and-retry-reachable", app)
    retry.tap()
    _ = try waitSample(app) { $0.sampleCount >= before.sampleCount + 3 }
    let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: retry)
    XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
    XCTAssertTrue(!remote.exists || !remote.isEnabled)
    let after = try sample(app)
    XCTAssertEqual(after.localSaveCalls, before.localSaveCalls)
    XCTAssertGreaterThanOrEqual(after.transport.refusedRequests, before.transport.refusedRequests)
    assertIsolation(after)
    capture("settings-31-local-remote-retry-remains-unconfirmed", app)
    // Zero HTTP calls is legitimate for a nil-client/admission rejection. The
    // attached before/after records do not claim successful service retry.
  }

  func testFullMaximumTextSizeChoicesUseActualCategoryAcrossRotation() throws {
    let app = try launch(screen: "textReadability", extra: ["--settings-large-text", "--settings-dark"])
    XCTAssertTrue(app.navigationBars["Text & Readability"].waitForExistence(timeout: 8))
    let native = try sample(app)
    XCTAssertEqual(native.systemTextCategory, "UICTContentSizeCategoryAccessibilityXL")
    XCTAssertEqual(native.fontManagerTextCategory, native.systemTextCategory)
    XCTAssertEqual(native.nativeWindowStyle, 2)
    let picker = app.buttons["text.maxSize"].firstMatch
    try reveal(picker, app)
    XCTAssertEqual(picker.value as? String, textChoices.last)
    capture("settings-32-native-accessibility-category-and-full-current-cap", app)
    for (index, choice) in textChoices.enumerated() {
      try reveal(picker, app)
      picker.tap()
      let menu = try waitMenu(app)
      let button = menu.buttons[choice].firstMatch
      try revealMenuChoice(button, menu: menu, app: app)
      XCTAssertEqual(button.label, choice)
      capture("settings-\(33 + index)-full-text-cap-choice-\(index + 1)", app)
      button.tap()
      let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", choice), object: picker)
      XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }
    let saved = try waitSample(app) { $0.maxTextSize == "accessibility5" && $0.persistenceState == "ready" }
    assertIsolation(saved)
    try reveal(picker, app)
    capture("settings-40-highest-cap-selected-with-full-value", app)
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
    capture("settings-41-landscape-native-window-and-full-cap", app)
  }

  private func launch(screen: String = "root", extra: [String] = []) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--settings-ui-fixture", "--settings-screen=" + screen,
      "-defaultComposerLanguage", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-UIPreferredContentSizeCategoryName", extra.contains("--settings-large-text")
        ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"] + extra
    app.launch()
    let probe = app.descendants(matching: .any)["settings.fixture.counters"].firstMatch
    XCTAssertTrue(probe.waitForExistence(timeout: 8), "A setup failure cannot be treated as an unavailable destination")
    let value = try waitSample(app) { $0.ready }
    assertIsolation(value)
    XCTAssertEqual(value.systemTextCategory, extra.contains("--settings-large-text")
      ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL")
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
    for attempt in 0..<12 {
      if element.exists && element.isHittable && receivingViewport(app).insetBy(dx: -1, dy: -1).contains(element.frame) { return }
      if attempt < 11 { if upward { app.swipeUp() } else { app.swipeDown() } }
    }
    XCTFail("Expected a fully reachable native control: \(element.identifier)")
    throw FixtureError.controlNotReached
  }
  private func receivingViewport(_ app: XCUIApplication) -> CGRect {
    let window = app.windows.firstMatch.frame
    let form = app.collectionViews.firstMatch
    var viewport = form.exists ? window.intersection(form.frame) : window
    let navigation = app.navigationBars.firstMatch.frame
    let top = max(viewport.minY, navigation.maxY)
    var bottom = viewport.maxY
    if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY) }
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
  private func capture(_ name: String, _ app: XCUIApplication) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    let hierarchy = app.debugDescription
    let ax = XCTAttachment(string: String(hierarchy.prefix(40_000))
      + "\nAX character limit=40000; truncated=\(hierarchy.count > 40_000)")
    ax.name = name + " — bounded native AX hierarchy"; ax.lifetime = .keepAlways; add(ax)
    let raw = app.descendants(matching: .any)["settings.fixture.counters"].firstMatch.value as? String ?? "missing probe"
    let receipt = XCTAttachment(string: raw + "\nwindow=\(app.windows.firstMatch.frame); receiving=\(receivingViewport(app))")
    receipt.name = name + " — actual state, refused transport and native geometry"
    receipt.lifetime = .keepAlways; add(receipt)
  }
  private enum FixtureError: Error { case controlNotReached, sampleMissing }
  private struct Transport: Decodable { let refusedRequests: Int, attemptedWrites: Int, unexpectedRequests: Int }
  private struct Sample: Decodable {
    let ready: Bool, sampleCount: Int, noAuthenticatedHost: Bool
    let draftTestingConfigurationApplied: Bool, currentDraftAbsent: Bool
    let editingDefaultsSuite: String, persistenceState: String, canEditLocalSettings: Bool
    let localFetchCalls: Int, localSaveCalls: Int, fakeSupportPurchaseAttempts: Int
    let maxTextSize: String, globalOrGroupDefaultsChangedKeys: [String]
    let transport: Transport
    let systemTextCategory: String, fontManagerTextCategory: String, nativeWindowStyle: Int
    let nativeWindowWidth: Double, nativeWindowHeight: Double
  }
}
