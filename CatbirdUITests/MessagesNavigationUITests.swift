import XCTest

/// Native Messages split navigation and production transcript states. Fixture
/// controls deliver URLs/reselection events; they never implement navigation.
@MainActor
final class MessagesNavigationUITests: XCTestCase {
  private var app: XCUIApplication!
  private let conversationID = "messages-navigation-fixture"

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  override func tearDownWithError() throws { app = nil }

  func testBackThenOtherTabThenMessagesStaysAtConversationList() throws {
    launch()
    openConversationFromList()
    capture("01-native-conversation-detail")
    tapBack()
    assertConversationList()
    tapTab("home")
    waitForState { $0["selectedTab"] as? Int == 0 }
    tapTab("messages")
    assertConversationList()
    XCTAssertFalse(app.staticTexts["No Messages Yet"].exists)
    capture("02-back-other-tab-messages-list")
  }

  func testSelectedMessagesReselectionReturnsToListAndRemainsAtRoot() throws {
    launch()
    openConversationFromList()
    // Native compact detail hides its tab bar. Deliver the production binding
    // event here, then exercise actual native retaps when the bar is visible.
    app.buttons["messages-navigation.reselect"].tap()
    assertConversationList()
    tapTab("messages")
    assertConversationList()
    tapTab("messages")
    assertConversationList()
    capture("03-messages-reselection-root")
  }

  func testRepeatedConversationLinksAreConsumedWithoutReopeningAfterBack() throws {
    launch()
    app.buttons["messages-navigation.conversation-link"].tap()
    assertConversation()
    waitForState { $0["deliveredLinks"] as? Int == 1 && $0["pendingConversation"] as? String == "" }
    app.buttons["messages-navigation.conversation-link"].tap()
    waitForState { $0["deliveredLinks"] as? Int == 2 && $0["pendingConversation"] as? String == "" }
    assertConversation()
    capture("04-repeated-conversation-link-consumed")
    tapBack()
    assertConversationList()
    tapTab("home")
    waitForState { $0["selectedTab"] as? Int == 0 }
    tapTab("messages")
    assertConversationList()
    capture("05-repeated-link-back-remains-list")
  }

  func testExplicitMessagesRootURLClearsDetailAndPreservesNextConversationLink() throws {
    launch()
    openConversationFromList()
    app.buttons["messages-navigation.nested-detail"].tap()
    waitForState { $0["chatDepth"] as? Int == 1 }
    XCTAssertTrue(app.navigationBars["#messages-route-fixture"].waitForExistence(timeout: 10))
    capture("06a-real-nested-detail")
    app.buttons["messages-navigation.root-link"].tap()
    assertConversationList()
    waitForState { $0["deliveredLinks"] as? Int == 1 }
    capture("06-explicit-messages-root")
    tapTab("home")
    waitForState { $0["selectedTab"] as? Int == 0 }
    app.buttons["messages-navigation.conversation-link"].tap()
    assertConversation()
    waitForState { $0["deliveredLinks"] as? Int == 2 && $0["pendingConversation"] as? String == "" }
    capture("07-intentional-conversation-link-from-other-tab")
  }

  func testConversationLinkDeliveredBeforeMessagesMountsOpensItsDetail() throws {
    launch(initialLink: true)
    assertConversation()
    waitForState { $0["deliveredLinks"] as? Int == 1 && $0["pendingConversation"] as? String == "" }
    capture("08a-conversation-link-before-tab-mount")
    tapBack()
    assertConversationList()
  }

  func testColdLaunchDoesNotRestorePreviouslySelectedConversation() throws {
    launch()
    openConversationFromList()
    app.terminate()
    app.launch()
    waitForFixture()
    assertConversationList()
    XCTAssertFalse(app.staticTexts["No Messages Yet"].exists)
    capture("08-cold-launch-messages-list")
  }

  func testFailedInitialLoadShowsRetryAndSuccessfulRetryShowsMessage() throws {
    launch(failedLoad: true)
    let row = app.staticTexts["Local Chat Partner"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    let failure = app.staticTexts["Couldn’t Load Messages"].firstMatch
    XCTAssertTrue(failure.waitForExistence(timeout: 20), "Initial failure must render an inline retry state")
    XCTAssertFalse(app.staticTexts["No Messages Yet"].exists, "A failed request does not prove the conversation is empty")
    XCTAssertFalse(app.alerts.firstMatch.exists, "Inline retry should not require dismissing a general error alert")
    let retry = app.buttons["Try Again"].firstMatch
    XCTAssertTrue(retry.exists)
    capture("09-initial-message-load-failed")

    // A retry while the service is still unavailable must remain a failure,
    // never turn into the successful-empty transcript.
    let initialReads = try XCTUnwrap(state()["messageReads"] as? Int)
    retry.tap()
    waitForState(timeout: 20) { ($0["messageReads"] as? Int ?? 0) > initialReads }
    XCTAssertTrue(failure.waitForExistence(timeout: 20))
    XCTAssertFalse(app.staticTexts["No Messages Yet"].exists)
    capture("10-failed-retry-remains-error")

    app.buttons["messages-navigation.restore-service"].tap()
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    let readsBeforeRecovery = try XCTUnwrap(state()["messageReads"] as? Int)
    retry.tap()
    // Text-only bubbles expose one VoiceOver element, whatever its element type, labelled
    // with sender, text and localized time. Match its fixed prefix, leaving the time variable.
    let recovered = app.descendants(matching: .any)["chat.message.recovered-message"]
    XCTAssertTrue(recovered.waitForExistence(timeout: 15), "The production retry must render the recovered response")
    XCTAssertTrue(recovered.label.hasPrefix("Local Chat Partner, Recovered local message after retry., "),
      "Unexpected VoiceOver label: \(recovered.label)")
    XCTAssertTrue(recovered.isHittable, "The recovered message must be visible in the transcript")
    waitForState { ($0["messageReads"] as? Int ?? 0) > readsBeforeRecovery }
    XCTAssertFalse(failure.exists)
    XCTAssertFalse(app.staticTexts["No Messages Yet"].exists)
    XCTAssertFalse(retry.exists)
    capture("11-message-load-recovered-after-native-retry")
  }

  private func launch(failedLoad: Bool = false, initialLink: Bool = false) {
    app.launchArguments = ["--messages-navigation-ui-fixture", "-defaultComposerLanguage", "en"]
    if failedLoad { app.launchArguments.append("--messages-navigation-failed-load") }
    if initialLink { app.launchArguments.append("--messages-navigation-initial-link") }
    app.launch()
    waitForFixture()
    if !initialLink { assertConversationList() }
  }

  private func waitForFixture() {
    XCTAssertTrue(app.staticTexts["messages-navigation.probe"].waitForExistence(timeout: 15))
    waitForState(timeout: 15) { ($0["listReads"] as? Int ?? 0) > 0 }
  }

  private func openConversationFromList() {
    let row = app.staticTexts["Local Chat Partner"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    XCTAssertTrue(row.isHittable)
    row.tap()
    assertConversation()
  }

  private func assertConversation(file: StaticString = #filePath, line: UInt = #line) {
    waitForState(file: file, line: line) {
      $0["selectedTab"] as? Int == 4 && $0["activeConversation"] as? String == self.conversationID
    }
    XCTAssertTrue(app.staticTexts["No Messages Yet"].firstMatch.waitForExistence(timeout: 10),
      "Only a successful empty response should show the empty transcript", file: file, line: line)
    XCTAssertTrue(app.navigationBars.staticTexts["Local Chat Partner"].firstMatch.exists,
      "Expected the actual conversation navigation title", file: file, line: line)
  }

  private func assertConversationList(file: StaticString = #filePath, line: UInt = #line) {
    let otherRow = app.staticTexts["Another Local Chat"].firstMatch
    let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { otherRow.exists && otherRow.isHittable } }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10),
      .completed, "Expected the actual conversation list", file: file, line: line)
    waitForState(file: file, line: line) {
      $0["selectedTab"] as? Int == 4 && $0["chatDepth"] as? Int == 0 &&
        $0["pendingConversation"] as? String == "" && $0["activeConversation"] as? String == ""
    }
  }

  private func tapBack() {
    let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Back' OR label == 'Messages'")).firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected the native split-view Back button")
    back.tap()
  }

  private func tapTab(_ name: String) {
    let identified = app.buttons["tab_\(name)"].firstMatch
    let named = app.tabBars.buttons[name.capitalized].firstMatch
    let tab = identified.exists ? identified : named
    XCTAssertTrue(tab.waitForExistence(timeout: 5), "Expected native \(name) tab")
    XCTAssertTrue(tab.isHittable)
    tab.tap()
  }

  private func state() -> [String: Any] {
    guard let value = app.staticTexts["messages-navigation.probe"].firstMatch.value as? String,
      let data = value.data(using: .utf8),
      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return result
  }

  private func waitForState(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping ([String: Any]) -> Bool) {
    let predicate = NSPredicate { [weak self] _, _ in
      MainActor.assumeIsolated { self.map { condition($0.state()) } ?? false }
    }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout),
      .completed, "Native state: \(state())", file: file, line: line)
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
