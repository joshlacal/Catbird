import XCTest

/// Visual states of focused Search and Discover Feeds, using the local Search fixture.
/// No request leaves the device; screenshots are kept as attachments for review.
@MainActor
final class SearchAndFeedDiscoveryVisualUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws { app = nil }

  func testFocusedSearchWithHistoryAndTypeahead() throws {
    launch(history: true)
    focusSearch()

    let queries = app.descendants(matching: .any)["search.history.queries"].firstMatch
    XCTAssertTrue(queries.waitForExistence(timeout: 5), "Recent searches render while focused")
    XCTAssertTrue(app.buttons["P(aul) Frazee"].firstMatch.exists, "Recently viewed profiles render")
    XCTAssertTrue(app.buttons["Clear recent searches"].firstMatch.exists)
    XCTAssertTrue(app.buttons["Edit tmz"].firstMatch.exists, "Each recent search can refill the field")
    XCTAssertFalse(app.descendants(matching: .any)["search.history.empty"].exists)
    capture("search-01-focused-history")

    // Filling keeps focus and switches to the typing state without submitting.
    app.buttons["Edit tmz"].firstMatch.tap()
    XCTAssertTrue(app.buttons["search.suggestion.submit"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.searchFields.firstMatch.value as? String, "tmz")
    XCTAssertTrue(app.keyboards.firstMatch.exists)

    app.searchFields.firstMatch.buttons.firstMatch.tap() // native clear
    app.searchFields.firstMatch.typeText("max")
    XCTAssertTrue(app.buttons["search.suggestion.submit"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Maxwell Frost"].waitForExistence(timeout: 5), "Typeahead profiles render")
    capture("search-02-typing-typeahead")

    XCTAssertTrue(app.buttons["Packs"].firstMatch.exists, "Starter packs scope fits the scope bar")
  }

  func testFocusedSearchWithoutHistoryShowsHint() throws {
    launch(history: false)
    focusSearch()
    let hint = app.descendants(matching: .any)["search.history.empty"].firstMatch
    XCTAssertTrue(hint.waitForExistence(timeout: 5), "Empty history has its own focused state")
    XCTAssertFalse(app.descendants(matching: .any)["search.history.queries"].exists)
    capture("search-03-focused-empty-history")
  }

  func testRecentSearchOverflowScrollsAndDismissesKeyboard() throws {
    try checkHistoryDragging(overflow: true, accessibilityText: false)
  }

  func testShortRecentSearchHistoryDismissesKeyboardAndCanRefocus() throws {
    try checkHistoryDragging(overflow: false, accessibilityText: false)
  }

  func testRecentSearchOverflowScrollsAtAccessibilityTextSize() throws {
    try checkHistoryDragging(overflow: true, accessibilityText: true)
  }

  func testRecentSearchHorizontalSwipeStillDeletesOnlyThatQuery() throws {
    launch(history: true, historyArgument: "--search-visual-history-overflow")
    focusSearch()
    waitForNativeState { $0["searchFocused"] as? Bool == true }
    let requests = try XCTUnwrap(nativeState()["searchRequests"] as? Int)
    let firstQuery = app.staticTexts["Scroll fixture query 01"].firstMatch
    XCTAssertTrue(firstQuery.waitForExistence(timeout: 5))
    XCTAssertTrue(firstQuery.isHittable)
    firstQuery.swipeLeft()
    let delete = app.buttons["Delete Scroll fixture query 01"].firstMatch
    XCTAssertTrue(delete.waitForExistence(timeout: 5), "Horizontal swiping exposes the native delete action")
    capture("search-scroll-horizontal-delete-revealed")
    delete.tap()
    XCTAssertTrue(firstQuery.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Scroll fixture query 02"].firstMatch.exists,
                  "Deleting a row must preserve the other history entries")
    XCTAssertEqual(nativeState()["searchText"] as? String, "")
    XCTAssertEqual(nativeState()["searchRequests"] as? Int, requests)
    capture("search-scroll-horizontal-delete-finished")
  }

  func testDiscoverFeedsSummaryActionsAndBrowsing() throws {
    launch(history: false)
    tapSearchTab()
    let customFeeds = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Custom Feeds'")).firstMatch
    for _ in 0..<6 where !customFeeds.isHittable { app.swipeUp() }
    XCTAssertTrue(customFeeds.waitForExistence(timeout: 5))
    customFeeds.tap()

    XCTAssertTrue(app.navigationBars["Discover Feeds"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Popular on Bluesky"].waitForExistence(timeout: 10),
                  "Storefront renders Popular on Bluesky shelf")
    XCTAssertTrue(app.staticTexts["For You"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Quiet Posters"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Science"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.searchFields["Search feeds"].waitForExistence(timeout: 5))
    capture("feeds-01-storefront")

    // Rapid-fire quick add from the Storefront row without leaving the storefront.
    let quietPostersURI = "at://did:plc:searchvisualcreator/app.bsky.feed.generator/feed1"
    let addFeedButton = app.buttons["feed.library.add.\(quietPostersURI)"].firstMatch
    XCTAssertTrue(addFeedButton.waitForExistence(timeout: 5), "Storefront row exposes instant Add pill")
    addFeedButton.tap()
    XCTAssertTrue(app.buttons["feed.library.manage.\(quietPostersURI)"].firstMatch.waitForExistence(timeout: 5),
                  "Quick add flips immediately to saved manage pill")
    capture("feeds-02-storefront-quick-added")

    // Tap a feed row to open its App Store-style Product Page with live posts and metadata strip.
    let forYouRow = app.buttons["feed.storefront.row.at://did:plc:searchvisualcreator/app.bsky.feed.generator/feed0"].firstMatch
    XCTAssertTrue(forYouRow.waitForExistence(timeout: 5))
    forYouRow.tap()

    XCTAssertTrue(app.staticTexts["LIKES"].waitForExistence(timeout: 5), "Product page displays Likes stat")
    XCTAssertTrue(app.staticTexts["VELOCITY"].waitForExistence(timeout: 5), "Product page displays Velocity stat")
    XCTAssertTrue(app.staticTexts["CREATOR"].waitForExistence(timeout: 5), "Product page displays Creator stat")
    let firstPost = app.staticTexts["last pic in the van! gg"].firstMatch
    XCTAssertTrue(firstPost.waitForExistence(timeout: 10), "Live post preview cards load on Product Page")
    XCTAssertTrue(app.buttons["feed.discovery.open"].firstMatch.exists)
    capture("feeds-03-product-page")

    // Return to storefront and test category chip filtering.
    app.navigationBars.buttons.firstMatch.tap()
    let scienceChip = app.buttons["feed.storefront.category.science"].firstMatch
    XCTAssertTrue(scienceChip.waitForExistence(timeout: 5))
    scienceChip.tap()
    XCTAssertTrue(app.staticTexts["Science & Nature"].waitForExistence(timeout: 5))
    capture("feeds-04-category-filter")

    app.buttons["feed.discovery.close"].tap()
    XCTAssertTrue(app.navigationBars["Discover Feeds"].waitForNonExistence(timeout: 5))
  }

  // MARK: - Helpers

  func testLargeTrendingTopicCardFromExploreMore() throws {
    try checkLargeTrendingTopic(accessibilityText: false)
  }

  func testLargeTrendingTopicCardAtAccessibilityTextSize() throws {
    try checkLargeTrendingTopic(accessibilityText: true)
  }

  private func launch(history: Bool, historyArgument: String? = nil, accessibilityText: Bool = false,
                      topics: Bool = false) {
    app = XCUIApplication()
    app.launchArguments = ["--search-tab-reselection-ui-fixture", "--search-visual-fixture"]
      + (history ? ["--search-visual-history"] : [])
    if let historyArgument { app.launchArguments.append(historyArgument) }
    if topics { app.launchArguments.append("--search-visual-large-topics") }
    if accessibilityText {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }
    app.launch()
    XCTAssertTrue(app.staticTexts["search-tabs.probe"].waitForExistence(timeout: 15))
  }

  private func tapSearchTab() {
    let identified = app.buttons["tab_search"].firstMatch
    let button = identified.waitForExistence(timeout: 5) ? identified : app.tabBars.buttons["Search"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
    if !app.searchFields.firstMatch.waitForExistence(timeout: 3) {
      button.tap()
    }
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
  }

  private func focusSearch() {
    tapSearchTab()
    app.searchFields.firstMatch.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
  }

  private func checkHistoryDragging(overflow: Bool, accessibilityText: Bool) throws {
    let variant = overflow ? "overflow" : "short"
    let name = "search-scroll-\(variant)\(accessibilityText ? "-accessibility" : "")"
    launch(history: true, historyArgument: "--search-visual-history-\(variant)",
           accessibilityText: accessibilityText)
    focusSearch()
    waitForNativeState { $0["searchFocused"] as? Bool == true }
    if accessibilityText {
      XCTAssertEqual(nativeState()["windowContentSizeCategory"] as? String, "UICTContentSizeCategoryAccessibilityXXXL",
                     "The app window must actually use the requested accessibility text size")
    }
    let requests = try XCTUnwrap(nativeState()["searchRequests"] as? Int)
    let firstQuery = app.staticTexts["Scroll fixture query 01"].firstMatch
    XCTAssertTrue(firstQuery.waitForExistence(timeout: 5))
    capture("\(name)-01-keyboard-shown")

    // Drag the query itself, where the old custom row recognizer intercepted the pan.
    // Overflow must actually advance the native scroll offset, not merely hide the keyboard.
    try dragRecentQuery(upward: overflow)
    waitForNativeState { ($0["searchVerticalPanDistance"] as? Double ?? 0) > 24 }
    if overflow {
      waitForNativeState { ($0["searchScrollOffsetAdvance"] as? Double ?? 0) > 20 }
    }
    // Interactive dismissal can retain the keyboard during an upward scroll; pulling
    // downward must dismiss it. An on-drag dismissal may have already done so.
    if app.keyboards.firstMatch.exists { try dragRecentQuery(upward: false) }
    assertHistoryDragDismissedKeyboard(requests: requests)
    capture("\(name)-02-drag-dismissed")

    // Exercise the existing production tab-reselection consumer after native dismissal.
    let reselect = app.buttons["search-tabs.reselect"]
    XCTAssertTrue(reselect.waitForExistence(timeout: 5))
    reselect.tap()
    waitForNativeState { $0["searchFocused"] as? Bool == true }
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    try dragRecentQuery(upward: false)
    waitForNativeState { ($0["searchVerticalPanDistance"] as? Double ?? 0) > 24 }
    assertHistoryDragDismissedKeyboard(requests: requests)
    capture("\(name)-03-repeat-dismissed")
  }

  private func dragRecentQuery(upward: Bool) throws {
    // XCUITest's keyboard frame leaves out the input assistant bar above the keys, which can cover
    // the lowest "visible" row on a tall screen; the app reports the full keyboard frame.
    let reportedKeyboardTop = (nativeState()["keyboardTop"] as? Double).flatMap { $0 >= 0 ? CGFloat($0) : nil }
    let keyboardTop = app.keyboards.firstMatch.exists
      ? min(app.keyboards.firstMatch.frame.minY, reportedKeyboardTop ?? .infinity) : app.frame.maxY
    let contentTop = max(app.navigationBars.firstMatch.frame.maxY,
                         app.searchFields.firstMatch.frame.maxY, app.frame.minY + 60)
    let queries = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scroll fixture query '"))
      .allElementsBoundByIndex.filter {
        $0.isHittable && $0.frame.minY > contentTop + 8 && $0.frame.maxY < keyboardTop - 8
      }
      .sorted { $0.frame.midY < $1.frame.midY }
    let query = try XCTUnwrap(upward ? queries.last : queries.first,
                             "A recent-query label must be hittable above the keyboard")
    let availableDistance = upward ? query.frame.midY - contentTop - 8 : app.frame.maxY - query.frame.midY - 40
    // A downward drag continues through the keyboard's former area so an interactive
    // dismissal completes instead of springing back after a partial pull.
    let distance = upward ? min(160, availableDistance) : availableDistance
    XCTAssertGreaterThan(distance, 48, "The gesture must have enough room to become a real scroll pan")
    let start = query.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = start.withOffset(CGVector(dx: 0, dy: upward ? -distance : distance))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
  }

  private func assertHistoryDragDismissedKeyboard(requests: Int) {
    capture("search-scroll-before-dismissal-assert")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                  "Dragging recent searches must dismiss the keyboard, including short history")
    waitForNativeState { $0["searchFocused"] as? Bool == false }
    XCTAssertEqual(nativeState()["searchText"] as? String, "", "Dragging must not fill or submit a query")
    XCTAssertEqual(nativeState()["searchRequests"] as? Int, requests, "Dragging must not execute a search")
    XCTAssertEqual(nativeState()["searchDepth"] as? Int, 0, "Dragging must not open a destination")
  }

  private func nativeState() -> [String: Any] {
    guard let value = app.staticTexts["search-tabs.probe"].firstMatch.value as? String,
          let data = value.data(using: .utf8),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return state
  }

  private func waitForNativeState(_ condition: @escaping ([String: Any]) -> Bool) {
    let predicate = NSPredicate { [weak self] _, _ in
      MainActor.assumeIsolated { self.map { condition($0.nativeState()) } ?? false }
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                   "Native Search state: \(nativeState())")
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let state = XCTAttachment(string: String(describing: nativeState()))
    state.name = "\(name)-native-state"
    state.lifetime = .keepAlways
    add(state)
  }
}

private extension SearchAndFeedDiscoveryVisualUITests {
  func checkLargeTrendingTopic(accessibilityText: Bool) throws {
    launch(history: false, accessibilityText: accessibilityText, topics: true)
    tapSearchTab()
    if accessibilityText {
      XCTAssertEqual(nativeState()["windowContentSizeCategory"] as? String, "UICTContentSizeCategoryAccessibilityXXXL")
    }
    // Enter through Explore More, not the compact topic section or feed interstitial.
    let allTopics = app.buttons.matching(NSPredicate(format: "label CONTAINS 'All Trending Topics'")).firstMatch
    for _ in 0..<20 where !allTopics.isHittable { app.swipeUp() }
    XCTAssertTrue(allTopics.waitForExistence(timeout: 5))
    XCTAssertTrue(allTopics.isHittable)
    allTopics.tap()
    XCTAssertTrue(app.navigationBars["Trending Topics"].waitForExistence(timeout: 5))

    let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Local Night Sky'")).firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5), "The deterministic large topic card must render")
    let suffix = accessibilityText ? "accessibility" : "standard"
    capture("trends-large-\(suffix)-01-top")
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "trends-large-\(suffix)-accessibility-tree"
    tree.lifetime = .keepAlways
    add(tree)
    app.swipeUp()
    capture("trends-large-\(suffix)-02-metadata")

    // The card keeps its original feed route and closes the topic browser.
    card.tap()
    XCTAssertTrue(app.navigationBars["Trending Topics"].waitForNonExistence(timeout: 5))
    waitForNativeState { ($0["searchDepth"] as? Int ?? 0) > 0 }
    capture("trends-large-\(suffix)-03-topic-opened")
  }
}
