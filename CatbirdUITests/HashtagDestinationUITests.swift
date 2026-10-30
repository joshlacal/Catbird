import XCTest

/// Production HashtagView, navigation, moderation, and request encoding against
/// the local Search fixture. Response text reflects the actual request parameters.
@MainActor
final class HashtagDestinationUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if testRun?.hasSucceeded == false, app?.state == .runningForeground {
      capture("hashtag-failure", includeTree: true)
    }
    app?.terminate()
    app = nil
  }

  func testSingleTitleAndHeaderScrollWithPosts() throws {
    launch()
    waitForDisplayRequest(sort: "latest")
    XCTAssertTrue(postText("Hashtag latest any row 01.").waitForExistence(timeout: 8))
    XCTAssertTrue(app.navigationBars["#localtopic"].exists)
    XCTAssertFalse(app.staticTexts["Posts with this hashtag"].exists)
    let firstPost = postText("Hashtag latest any row 01.")
    let headings = app.staticTexts.matching(NSPredicate(format: "label == %@", "#localtopic"))
      .allElementsBoundByIndex.filter { $0.isHittable && $0.frame.maxY <= firstPost.frame.minY }
    XCTAssertEqual(headings.count, 1, "The navigation title must be the only hashtag heading above the posts")
    XCTAssertTrue(sortControl.isHittable)
    XCTAssertTrue(app.buttons["#relatedtopic"].firstMatch.waitForExistence(timeout: 8),
                  "Related hashtag navigation remains available in the scrolling header")
    capture("hashtag-01-compact-header")

    let originalOffset = try scrollOffset()
    app.buttons["#relatedtopic"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["#relatedtopic"].waitForExistence(timeout: 5))
    waitForState { state in
      let request = state["hashtagLastRequest"] as? [String: String]
      return state["searchDepth"] as? Int == 2 && request?["q"] == "#relatedtopic"
        && request?["limit"] == "30"
    }
    XCTAssertTrue(postText("Hashtag latest any row 01.").waitForExistence(timeout: 8))
    let relatedRequests = try displayRequestCount()
    capture("hashtag-01-related-destination")
    let relatedNavigation = app.navigationBars["#relatedtopic"]
    let namedBack = relatedNavigation.buttons.matching(NSPredicate(format: "label == '#localtopic' OR label == 'Back'"))
      .firstMatch
    let back = namedBack.exists ? namedBack : relatedNavigation.buttons.firstMatch
    XCTAssertNotEqual(back.identifier, "hashtag.languageFilter", "Return using the native back button")
    back.tap()
    XCTAssertTrue(app.navigationBars["#localtopic"].waitForExistence(timeout: 5))
    waitForState { $0["searchDepth"] as? Int == 1 }
    XCTAssertTrue(firstPost.waitForExistence(timeout: 5))
    XCTAssertEqual(try scrollOffset(), originalOffset, accuracy: 12)
    assertNoDisplayReload(requests: relatedRequests)
    XCTAssertTrue(sortControl.isHittable)

    let before = try scrollOffset()
    for _ in 0..<4 where sortControl.isHittable { postsList.swipeUp() }
    waitForState { ($0["hashtagScrollOffset"] as? Double ?? -1) > before + 100 }
    XCTAssertFalse(sortControl.isHittable, "Sorting and related tags scroll away with the posts")
    XCTAssertTrue(app.navigationBars["#localtopic"].isHittable, "The compact navigation title remains")
    XCTAssertTrue(languageFilterButton.isHittable, "Language filtering stays reachable after scrolling")
    capture("hashtag-02-header-scrolled")
  }

  func testLatestAndTopChangeRequestAndRenderedResults() throws {
    launch()
    waitForDisplayRequest(sort: "latest")
    XCTAssertTrue(postText("Hashtag latest any row 01.").waitForExistence(timeout: 8))
    let initialRequests = try displayRequestCount()

    try chooseSort("Top")
    waitForDisplayRequest(sort: "top", after: initialRequests)
    XCTAssertTrue(postText("Hashtag top any row 01.").waitForExistence(timeout: 8))
    XCTAssertFalse(postText("Hashtag latest any row 01.").exists,
                   "Changing sort must replace the previous result set")
    capture("hashtag-03-top-results")

    let topRequests = try displayRequestCount()
    try chooseSort("Latest")
    waitForDisplayRequest(sort: "latest", after: topRequests)
    XCTAssertTrue(postText("Hashtag latest any row 01.").waitForExistence(timeout: 8))
    XCTAssertFalse(postText("Hashtag top any row 01.").exists)
    capture("hashtag-04-latest-results")
  }

  func testLanguageApplyCancelAndUnchangedApplyPreservePosition() throws {
    launch()
    waitForDisplayRequest(sort: "latest")
    XCTAssertTrue(postText("Hashtag latest any row 01.").waitForExistence(timeout: 8))
    let initialRequests = try displayRequestCount()

    openLanguageSheet()
    try chooseLanguage("English")
    dismissLanguageSheet(using: "Apply")
    waitForDisplayRequest(sort: "latest", language: "en", after: initialRequests)
    XCTAssertTrue(postText("Hashtag latest en row 01.").waitForExistence(timeout: 8))
    assertLanguageFilter("English")
    capture("hashtag-05-english-applied")

    postsList.swipeUp()
    postsList.swipeUp()
    waitForState { ($0["hashtagScrollOffset"] as? Double ?? -1) > 100 }
    XCTAssertFalse(app.buttons["Language: English"].firstMatch.isHittable,
                   "The persistent toolbar must expose the applied language after its header scrolls away")
    assertLanguageFilter("English")
    let anchor = try visiblePost(prefix: "Hashtag latest en row ")
    let anchorText = anchor.label
    let position = try scrollOffset()
    let appliedRequests = try displayRequestCount()

    openLanguageSheet()
    try chooseLanguage("Japanese")
    dismissLanguageSheet(using: "Cancel")
    try assertPreserved(position: position, anchorText: anchorText, requests: appliedRequests)
    assertLanguageFilter("English")
    capture("hashtag-06-language-cancel-preserves-position")

    // Reopening constructs a fresh draft from the applied language. Applying
    // without an edit must not reload, even after a different draft was canceled.
    openLanguageSheet()
    dismissLanguageSheet(using: "Apply")
    try assertPreserved(position: position, anchorText: anchorText, requests: appliedRequests)
    assertLanguageFilter("English")
    capture("hashtag-07-unchanged-apply-preserves-position")

    openLanguageSheet()
    try chooseLanguage("Japanese")
    dismissLanguageSheet(using: "Apply")
    waitForDisplayRequest(sort: "latest", language: "ja", after: appliedRequests)
    XCTAssertTrue(postText("Hashtag latest ja row ").waitForExistence(timeout: 8))
    assertLanguageFilter("Japanese")
    capture("hashtag-08-japanese-applied")

    let japaneseRequests = try displayRequestCount()
    openLanguageSheet()
    try chooseLanguage("Any")
    dismissLanguageSheet(using: "Apply")
    waitForDisplayRequest(sort: "latest", after: japaneseRequests)
    XCTAssertTrue(postText("Hashtag latest any row ").waitForExistence(timeout: 8))
    assertLanguageFilter("Any language")
    capture("hashtag-08-any-language-restored")
  }

  func testModeratedEmptyFirstPageCanLoadVisibleSecondPage() throws {
    launch(moderatedFirstPage: true)
    waitForDisplayRequest(sort: "latest")
    XCTAssertTrue(app.staticTexts["No matching posts"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.staticTexts["Be the first to post about this topic!"].exists)
    XCTAssertFalse(postText("Muted hashtag fixture post.").exists,
                   "The first page must be filtered by production moderation")
    let requests = try displayRequestCount()
    let loadMore = app.buttons["Load More"].firstMatch
    for _ in 0..<4 where !loadMore.isHittable { postsList.swipeUp() }
    XCTAssertTrue(loadMore.isHittable, "A cursor must remain reachable when moderation hides every post")
    capture("hashtag-09-moderated-page-can-continue")
    loadMore.tap()

    waitForDisplayRequest(sort: "latest", cursor: "hashtag-next", after: requests)
    XCTAssertTrue(postText("Hashtag latest any page 2 row ").waitForExistence(timeout: 8))
    XCTAssertFalse(app.staticTexts["No matching posts"].exists)
    XCTAssertEqual(try displayRequestCount(), requests + 1,
                   "Continuing should fetch the cursor once, without restarting the first page")
    capture("hashtag-10-visible-second-page")
  }

  func testAccessibilitySizeUsesReachableSortMenu() throws {
    launch(accessibilityText: true)
    waitForDisplayRequest(sort: "latest")
    XCTAssertTrue(postText("Hashtag latest any row 01.").waitForExistence(timeout: 8))
    XCTAssertEqual(nativeState()["windowContentSizeCategory"] as? String,
                   "UICTContentSizeCategoryAccessibilityXXXL")
    XCTAssertTrue(sortControl.isHittable)
    XCTAssertGreaterThan(sortControl.frame.height, 0)
    XCTAssertGreaterThanOrEqual(sortControl.frame.minX, postsList.frame.minX - 1)
    XCTAssertLessThanOrEqual(sortControl.frame.maxX, postsList.frame.maxX + 1,
                             "The accessibility selector must fit the available width")
    XCTAssertNil(hittableChoice("Top"),
                 "Accessibility sizes expose a menu instead of any visible Top segment")
    let requests = try displayRequestCount()
    sortControl.tap()
    let top = try waitForChoice("Top")
    capture("hashtag-11-accessibility-sort-menu", includeTree: true)
    top.tap()
    waitForDisplayRequest(sort: "top", after: requests)
    XCTAssertTrue(postText("Hashtag top any row 01.").waitForExistence(timeout: 8))
    capture("hashtag-12-accessibility-top-results")
  }

  // MARK: - Fixture and request evidence

  private func launch(moderatedFirstPage: Bool = false, accessibilityText: Bool = false) {
    app = XCUIApplication()
    app.launchArguments = ["--search-tab-reselection-ui-fixture", "--search-visual-fixture",
                           "--search-visual-hashtag", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if moderatedFirstPage { app.launchArguments.append("--search-visual-hashtag-moderated-page") }
    if accessibilityText {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }
    app.launch()
    XCTAssertTrue(app.staticTexts["search-tabs.probe"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.navigationBars["#localtopic"].waitForExistence(timeout: 10))
    XCTAssertTrue(postsList.waitForExistence(timeout: 5))
    waitForState { $0["selectedTab"] as? Int == 1 && $0["searchDepth"] as? Int == 1 }
  }

  private var postsList: XCUIElement { app.descendants(matching: .any)["hashtag.posts"].firstMatch }
  private var sortControl: XCUIElement { app.descendants(matching: .any)["hashtag.sort"].firstMatch }
  private var languageFilterButton: XCUIElement { app.buttons["hashtag.languageFilter"].firstMatch }

  private func postText(_ prefix: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
  }

  private func nativeState() -> [String: Any] {
    guard let value = app.staticTexts["search-tabs.probe"].firstMatch.value as? String,
          let data = value.data(using: .utf8),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return state
  }

  private func waitForState(timeout: TimeInterval = 8, _ condition: @escaping ([String: Any]) -> Bool) {
    let predicate = NSPredicate { [weak self] _, _ in
      MainActor.assumeIsolated { self.map { condition($0.nativeState()) } ?? false }
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                   "Native hashtag state: \(nativeState())")
  }

  private func waitForDisplayRequest(sort: String, language: String = "", cursor: String = "",
                                     after previousCount: Int = 0) {
    waitForState { state in
      guard let count = state["hashtagDisplayRequests"] as? Int, count > previousCount,
            let request = state["hashtagLastRequest"] as? [String: String] else { return false }
      return request["q"] == "#localtopic" && request["sort"] == sort
        && request["lang"] == language && request["cursor"] == cursor && request["limit"] == "30"
    }
    let history = nativeState()["hashtagRequests"] as? [[String: String]] ?? []
    XCTAssertTrue(history.contains { request in
      request["q"] == "#localtopic" && request["sort"] == sort && request["lang"] == language
        && request["cursor"] == cursor && request["limit"] == "30"
    }, "Request history must independently record the display parameters")
  }

  private func displayRequestCount() throws -> Int {
    try XCTUnwrap(nativeState()["hashtagDisplayRequests"] as? Int, "The fixture must publish request count")
  }

  private func scrollOffset() throws -> Double {
    try XCTUnwrap(nativeState()["hashtagScrollOffset"] as? Double, "The fixture must publish list position")
  }

  private func assertPreserved(position: Double, anchorText: String, requests: Int) throws {
    XCTAssertTrue(app.staticTexts[anchorText].firstMatch.waitForExistence(timeout: 5))
    waitForState { state in
      guard let offset = state["hashtagScrollOffset"] as? Double else { return false }
      return abs(offset - position) < 12
    }
    XCTAssertTrue(app.staticTexts[anchorText].firstMatch.isHittable,
                  "The same post remains visible after closing the filter sheet")
    XCTAssertEqual(try scrollOffset(), position, accuracy: 12)
    XCTAssertEqual(try displayRequestCount(), requests)
    assertNoDisplayReload(requests: requests)
  }

  private func assertNoDisplayReload(requests: Int) {
    let predicate = NSPredicate { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let count = self?.nativeState()["hashtagDisplayRequests"] as? Int else { return true }
        return count != requests
      }
    }
    let noReload = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    noReload.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [noReload], timeout: 0.8), .completed,
                   "Preserving the existing results must not schedule a delayed reload")
  }

  private func visiblePost(prefix: String) throws -> XCUIElement {
    let visible = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
      .allElementsBoundByIndex.filter {
        $0.isHittable && $0.frame.midY > app.navigationBars.firstMatch.frame.maxY
          && $0.frame.midY < app.frame.maxY - 80
      }.sorted { $0.frame.minY < $1.frame.minY }
    return try XCTUnwrap(visible.first, "A real post must be visible at the preserved list position")
  }

  // MARK: - Native picker interaction

  private func chooseSort(_ title: String) throws {
    // Native tabs and segmented pickers expose choices directly. The accessible
    // menu exposes its choices only after opening the identified control.
    if let direct = hittableChoice(title) { direct.tap(); return }
    XCTAssertTrue(sortControl.isHittable)
    sortControl.tap()
    try waitForChoice(title).tap()
  }

  private func assertLanguageFilter(_ language: String) {
    let expectedLabel = "Filter by language, \(language)"
    let predicate = NSPredicate { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let button = self?.languageFilterButton else { return false }
        return button.isHittable && button.label == expectedLabel
      }
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                   "The reachable language filter must announce its applied language")
    XCTAssertEqual(languageFilterButton.label, expectedLabel)
    XCTAssertTrue(languageFilterButton.isHittable)
  }

  private func openLanguageSheet() {
    XCTAssertTrue(languageFilterButton.isHittable)
    languageFilterButton.tap()
    XCTAssertTrue(app.navigationBars["Post Language"].waitForExistence(timeout: 5))
  }

  private func chooseLanguage(_ title: String) throws {
    if app.pickerWheels.firstMatch.exists {
      app.pickerWheels.firstMatch.adjust(toPickerWheelValue: title)
      return
    }
    let languageRow = app.buttons.matching(NSPredicate(format: "label == 'Language' OR label BEGINSWITH 'Language,' OR label BEGINSWITH 'Language '"))
      .allElementsBoundByIndex.first(where: \.isHittable)
      ?? app.cells.containing(.staticText, identifier: "Language").allElementsBoundByIndex.first(where: \.isHittable)
    let row = try XCTUnwrap(languageRow, "The native language Picker must expose a tappable row")
    row.tap()
    try waitForChoice(title).tap()
    // Some OS picker presentations use a navigation destination instead of a
    // menu. Return to the sheet controls without committing the draft.
    if !app.navigationBars["Post Language"].buttons["Apply"].firstMatch.isHittable {
      let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Post Language' OR label == 'Back'"))
        .firstMatch
      XCTAssertTrue(back.waitForExistence(timeout: 3))
      back.tap()
    }
    XCTAssertTrue(app.navigationBars["Post Language"].waitForExistence(timeout: 5))
  }

  private func dismissLanguageSheet(using title: String) {
    let action = app.navigationBars["Post Language"].buttons[title].firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    action.tap()
    XCTAssertTrue(app.navigationBars["Post Language"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["#localtopic"].waitForExistence(timeout: 5))
  }

  private func hittableChoice(_ title: String) -> XCUIElement? {
    let match = NSPredicate(format: "label == %@ OR identifier == %@", title, title)
    return app.buttons.matching(match).allElementsBoundByIndex.first(where: \.isHittable)
      ?? app.staticTexts.matching(match).allElementsBoundByIndex.first(where: \.isHittable)
  }

  private func waitForChoice(_ title: String) throws -> XCUIElement {
    let predicate = NSPredicate { [weak self] _, _ in
      MainActor.assumeIsolated { self?.hittableChoice(title) != nil }
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                   "The native picker must expose \(title)")
    return try XCTUnwrap(hittableChoice(title))
  }

  private func capture(_ name: String, includeTree: Bool = false) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let state = XCTAttachment(string: String(describing: nativeState()))
    state.name = "\(name)-native-state"
    state.lifetime = .keepAlways
    add(state)
    if includeTree {
      let tree = XCTAttachment(string: app.debugDescription)
      tree.name = "\(name)-accessibility-tree"
      tree.lifetime = .keepAlways
      add(tree)
    }
  }
}
