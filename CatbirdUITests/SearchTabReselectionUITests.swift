import XCTest

/// Production tab binding, Search view and Home collection; offline transport.
/// These tests exercise native focus/keyboard behavior, not a copied tap handler.
@MainActor
final class SearchTabReselectionUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--search-tab-reselection-ui-fixture"]
    app.launch()
    XCTAssertTrue(app.staticTexts["search-tabs.probe"].waitForExistence(timeout: 15))
    waitForState { $0["selectedTab"] as? Int == 0 }
  }

  override func tearDownWithError() throws { app = nil }

  func testFirstSelectionReselectionAndAlreadyFocusedPreserveTypedQuery() throws {
    tapTab("search")
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    waitForState { $0["selectedTab"] as? Int == 1 && $0["searchFocused"] as? Bool == false }
    XCTAssertFalse(app.keyboards.firstMatch.exists, "First selection only opens Search")
    capture("01-first-selection")

    // Waiting for the native UI above makes this an ordinary later reselection,
    // not a narrowly timed double-tap gesture.
    tapTab("search")
    waitForFocus(true)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    field.typeText("retained query")
    waitForState { $0["searchText"] as? String == "retained query" }
    tapTab("search")
    waitForState { $0["searchFocused"] as? Bool == true && $0["searchText"] as? String == "retained query" }
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    capture("02-already-focused-query-preserved")
  }

  func testSubmittedResultsNativeDismissalAndDeepDestinationReselection() throws {
    tapTab("search")
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    tapTab("search")
    waitForFocus(true)
    app.searchFields.firstMatch.typeText("fixture\n")
    waitForFocus(false)
    let result = app.staticTexts["Search fixture preserved result."].firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 10), "The real search request must render the local result")
    let requests = try XCTUnwrap(state()["searchRequests"] as? Int)
    XCTAssertGreaterThan(requests, 0)
    capture("03-submitted-search-results")

    tapTab("search")
    waitForState { $0["searchFocused"] as? Bool == true && $0["searchText"] as? String == "fixture" }
    XCTAssertEqual(state()["searchRequests"] as? Int, requests, "Reselection must not clear or refetch results")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    capture("04-results-refocused")

    // Submit through the native search key to dismiss the keyboard. Subsequent
    // reselection must be a fresh focus request even after earlier taps.
    app.searchFields.firstMatch.typeText("\n")
    waitForFocus(false)
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    tapTab("search")
    waitForFocus(true)
    XCTAssertEqual(state()["searchText"] as? String, "fixture")
    capture("05-refocused-after-native-dismissal")
    app.searchFields.firstMatch.typeText("\n")
    waitForFocus(false)
    XCTAssertTrue(result.waitForExistence(timeout: 10))

    result.tap()
    waitForState { $0["searchDepth"] as? Int == 1 }
    capture("06-search-detail")
    tapTab("search")
    waitForState { $0["searchDepth"] as? Int == 0 && $0["searchFocused"] as? Bool == false }
    XCTAssertTrue(result.waitForExistence(timeout: 5), "Returning to root preserves the committed result")
    XCTAssertEqual(state()["searchText"] as? String, "fixture")
    capture("07-detail-reselection-returns-to-results")
    tapTab("search")
    waitForState { $0["searchFocused"] as? Bool == true && $0["searchText"] as? String == "fixture" }
    capture("08-next-root-reselection-focuses")
  }

  func testReselectionEventFocusesWithoutResettingTheSearch() throws {
    tapTab("search")
    let reselect = app.buttons["search-tabs.reselect"]
    XCTAssertTrue(reselect.waitForExistence(timeout: 5))
    reselect.tap()
    waitForFocus(true)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.searchFields.firstMatch.typeText("fixture")
    reselect.tap()
    waitForState { $0["searchFocused"] as? Bool == true && $0["searchText"] as? String == "fixture" }
    app.searchFields.firstMatch.typeText("\n")
    waitForFocus(false)
    XCTAssertTrue(app.staticTexts["Search fixture preserved result."].firstMatch.waitForExistence(timeout: 10))
    reselect.tap()
    waitForState { $0["searchFocused"] as? Bool == true && $0["searchText"] as? String == "fixture" }
    capture("11-production-reselection-event-preserves-search")
  }

  func testHomeComposeButtonKeepsItsLaunchPositionAfterSwitchingTabs() throws {
    let composeButton = app.buttons["compose.fab"]
    XCTAssertTrue(composeButton.waitForExistence(timeout: 10))
    let initialFrame = composeButton.frame
    capture("home-compose-initial-position")

    tapTab("search")
    waitForState { $0["selectedTab"] as? Int == 1 }
    tapTab("home")
    waitForState { $0["selectedTab"] as? Int == 0 }
    XCTAssertTrue(composeButton.waitForExistence(timeout: 5))
    let returnedFrame = composeButton.frame
    XCTAssertEqual(initialFrame.minY, returnedFrame.minY, accuracy: 1,
                   "The compose button must not lose an extra bottom inset after switching tabs")
    XCTAssertEqual(initialFrame.minX, returnedFrame.minX, accuracy: 1)
    capture("home-compose-returned-position")
  }

  func testHomeRetapStillScrollsTheProductionFeedToTop() throws {
    waitForState(timeout: 15) { ($0["timelineReads"] as? Int ?? 0) > 0 && ($0["homeOffset"] as? Double ?? -1) >= 0 }
    let feed = app.collectionViews.firstMatch
    XCTAssertTrue(feed.waitForExistence(timeout: 5))
    feed.swipeUp()
    feed.swipeUp()
    waitForState { ($0["homeOffset"] as? Double ?? 0) > 150 }
    capture("09-home-scrolled")
    tapTab("search")
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    tapTab("home")
    waitForState { $0["selectedTab"] as? Int == 0 && ($0["homeOffset"] as? Double ?? 0) > 150 }
    tapTab("home")
    waitForState { $0["selectedTab"] as? Int == 0 && abs($0["homeOffset"] as? Double ?? -100) < 5 }
    capture("10-home-reselection-at-top")
  }

  private func tapTab(_ name: String) {
    let identified = app.buttons["tab_\(name)"].firstMatch
    let named = app.tabBars.buttons[name.capitalized].firstMatch
    let button = identified.exists ? identified : named
    if button.exists && button.isHittable {
      button.tap()
    } else if name == "search", app.searchFields.firstMatch.exists {
      // iOS 26 transforms the selected Search tab into its native field.
      // Deep destinations still exercise the actual tab-reselection callback.
      app.searchFields.firstMatch.tap()
    } else {
      XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected native \(name) tab")
      button.tap()
    }
  }

  private func waitForFocus(_ focused: Bool) {
    waitForState { $0["searchFocused"] as? Bool == focused }
  }

  private func state() -> [String: Any] {
    guard let value = app.staticTexts["search-tabs.probe"].firstMatch.value as? String,
          let data = value.data(using: .utf8),
          let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return result
  }

  private func waitForState(timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @escaping ([String: Any]) -> Bool) {
    let predicate = NSPredicate { [weak self] _, _ in
      MainActor.assumeIsolated { self.map { condition($0.state()) } ?? false }
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
      "Native state: \(state())", file: file, line: line)
  }

  private func capture(_ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let receipt = XCTAttachment(string: String(describing: state()))
    receipt.name = "\(name)-native-state"
    receipt.lifetime = .keepAlways
    add(receipt)
  }
}
