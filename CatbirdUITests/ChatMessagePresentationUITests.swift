import XCTest
import UIKit

/// Production UIKit transcript/cells, shared-record cards and message menus.
/// Synthetic records and action callbacks are local; no messages are transmitted.
@MainActor
final class ChatMessagePresentationUITests: XCTestCase {
  private let targetID = "presentation-target"
  private let title = "Local external card: a deliberately long headline that wraps at the message width cap"
  private let descriptionText = "Local description with enough words to wrap across several lines and expose a clipped final line. End of local description."
  private let recordBody = "Local shared post body with enough text to exercise the production quoted-post layout and its external preview. Final body marker."
  private var app: XCUIApplication!
  private var lastNativeMenuRequestCount = 0

  override func setUpWithError() throws { continueAfterFailure = false }
  override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait; app = nil }

  func testSharedExternalCardFitsAtWidthCapNarrowWidthRotationAndLargerText() throws {
    for scenario in ["external", "text-reply"] {
      launch(scenario)
      assertExternalCardFits()
      capture(scenario + "-width-cap")
      app.buttons["chat.fixture.narrow"].tap()
      waitForGeometry { $0.collectionFrame.width <= 260.7 && $0.isSettled }
      assertExternalCardFits()
      XCTAssertLessThan(bubble().frame.width, 260)
      capture(scenario + "-narrow")
      app.buttons["chat.fixture.narrow"].tap()
      XCUIDevice.shared.orientation = .landscapeLeft
      waitForGeometry { $0.collectionFrame.width > 402 && $0.isSettled }
      assertExternalCardFits()
      XCTAssertEqual(bubble().frame.width, 280, accuracy: 1, "The wide viewport must exercise the exact width cap")
      capture(scenario + "-landscape-width-cap")
      XCUIDevice.shared.orientation = .portrait
      waitForGeometry { $0.collectionFrame.width < 500 && $0.isSettled }
      assertExternalCardFits()
      let regularHeight = try XCTUnwrap(targetRow()).height
      let regularViewportWidth = geometry().collectionFrame.width
      let regularBubbleWidth = bubble().frame.width
      let regularTextFrames = [title, recordBody, descriptionText].map { text in
        (text: text, frame: staticText(exactLabel: text).frame)
      }
      capture(scenario + "-portrait-regular-text-before-scaling")
      // Fonts resolve from UIApplication's category at process startup. Use a
      // fresh UIKit test launch, not a local override of already-cached fonts.
      // This qualifies larger-text rendering, not an in-place settings change.
      app.terminate()
      launch(scenario, largerText: true)
      wait { (self.targetRow()?.height ?? 0) > regularHeight + 20 }
      waitForGeometry { $0.isSettled }
      XCTAssertEqual(geometry().collectionFrame.width, regularViewportWidth, accuracy: 1,
        "Font growth must be measured at the same portrait viewport width")
      XCTAssertEqual(bubble().frame.width, regularBubbleWidth, accuracy: 1,
        "A narrower bubble must not masquerade as Dynamic Type growth")
      for sample in regularTextFrames {
        let element = staticText(exactLabel: sample.text)
        XCTAssertGreaterThan(sample.frame.height, 0)
        wait { element.exists && element.frame.height > sample.frame.height + 1 }
        XCTAssertGreaterThan(element.frame.height, sample.frame.height + 1,
          "The actual hosted card text must grow across fresh launches at the same width")
      }
      assertExternalCardFits()
      capture(scenario + "-larger-text")
      assertNoSend()
      app.terminate()
    }
  }

  func testResolvedRecordGrowthShrinkReuseAndKeyboardPreserveTranscript() throws {
    launch("async")
    let original = try XCTUnwrap(targetRow())
    app.buttons["chat.fixture.changeRecord"].tap()
    waitForState { ($0["appliedRecordRevision"] as? Int) == 1 }
    assertExternalCardFits()
    wait { (self.targetRow()?.height ?? 0) > original.height + 20 }
    let grown = try XCTUnwrap(targetRow())
    XCTAssertGreaterThan(grown.height, original.height + 20)
    XCTAssertEqual(grown.cellIdentity, original.cellIdentity, "Asynchronous local resolution must resize the existing cell")
    assertBottomPin()
    capture("resolved-record-grew-in-place")

    let editor = productionEditor()
    editor.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    waitForGeometry { $0.editorIsFirstResponder && $0.isSettled }
    assertExternalCardFits()
    assertBottomPin()
    capture("resolved-record-keyboard-open")
    app.buttons["messages.fixture.dismissKeyboard"].tap()
    waitForGeometry { !$0.editorIsFirstResponder && $0.isSettled }

    // Read older rows, then update the bottom record while the reader is away.
    dragTranscript(towardOlder: true)
    dragTranscript(towardOlder: true)
    waitForGeometry { $0.isSettled }
    wait { self.targetRow() == nil }
    let reading = geometry()
    XCTAssertGreaterThan(reading.legalBottom - reading.offsetY, reading.footerFrame.height)
    app.buttons["chat.fixture.changeRecord"].tap()
    waitForState { ($0["appliedRecordRevision"] as? Int) == 2 }
    waitForGeometry { $0.isSettled && abs($0.offsetY - reading.offsetY) < 2 }
    XCTAssertEqual(geometry().anchorID, reading.anchorID)
    capture("record-shrank-with-reader-away")
    for _ in 0..<16 where abs(geometry().offsetY - geometry().legalBottom) > 2 {
      dragTranscript(towardOlder: false)
    }
    assertBottomPin()
    XCTAssertTrue(targetCell().waitForExistence(timeout: 5))
    wait { (self.targetRow()?.height ?? grown.height) < grown.height - 20 }
    XCTAssertLessThan(try XCTUnwrap(targetRow()).height, grown.height - 20)
    app.buttons["chat.fixture.changeRecord"].tap()
    waitForState { ($0["appliedRecordRevision"] as? Int) == 3 }
    assertExternalCardFits()
    capture("record-reused-and-grown-again")
    let repliesBefore = actions().filter { $0 == "reply|" + targetID }.count
    openMenu()
    XCTAssertFalse(menuAction("Copy").exists, "The reused media-only message still has no text to copy")
    XCTAssertTrue(menuAction("Reply").exists)
    capture("native-media-only-preview-after-cell-reuse")
    menuAction("Reply").tap()
    waitForAction("reply")
    waitForState {
      ($0["actions"] as? [String] ?? []).filter { $0 == "reply|" + self.targetID }.count == repliesBefore + 1
    }
    assertNoSend()
  }

  func testNativeIncomingMenuHasSixReactionsAndRetainsDraftAcrossRepeatedActions() throws {
    launch("menu-incoming")
    productionEditor().tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    waitForGeometry { $0.editorIsFirstResponder && $0.isSettled }
    let beforeCancellation = geometry()
    let actionsBeforeCancellation = actions()
    openMenu()
    capture("native-menu-before-cancel")
    // Dismiss the actual UIKit menu by tapping outside its preview/menu surface.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.20)).tap()
    wait { !self.menuAction("More Reactions").exists }
    assertNativeMenuWasUsed()
    XCTAssertEqual(actions(), actionsBeforeCancellation)
    XCTAssertEqual(productionEditor().value as? String, "local draft")
    productionEditor().tap()
    waitForGeometry { $0.editorIsFirstResponder && $0.isSettled }
    XCTAssertEqual(geometry().offsetY, beforeCancellation.offsetY, accuracy: 2)
    capture("native-menu-cancel-retained-draft-and-viewport")

    openMenu()
    menuAction("Copy").tap()
    waitForState { ($0["copiedSyntheticText"] as? Bool) == true }
    assertNativeMenuWasUsed()
    XCTAssertEqual(actions(), actionsBeforeCancellation, "Copy must not invoke message transport callbacks")
    XCTAssertEqual(productionEditor().value as? String, "local draft")
    for reaction in ["❤️", "👍", "😂", "😲", "😢", "🔥"] {
      openMenu()
      for required in ["❤️", "👍", "😂", "😲", "😢", "🔥", "More Reactions", "Reply", "Copy", "Delete for Me", "Report"] {
        XCTAssertTrue(menuAction(required).exists, "Native menu must retain " + required)
      }
      XCTAssertFalse(menuAction("Edit").exists)
      XCTAssertFalse(menuAction("Unsend").exists)
      capture("native-incoming-menu-" + reaction)
      menuAction(reaction).tap()
      waitForAction("add:" + reaction)
      XCTAssertEqual(productionEditor().value as? String, "local draft")
      productionEditor().tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }
    for action in [("More Reactions", "more"), ("Reply", "reply"), ("Delete for Me", "delete"), ("Report", "report")] {
      openMenu()
      menuAction(action.0).tap()
      waitForAction(action.1)
    }
    XCTAssertFalse(actions().contains { $0.hasPrefix("toggle:") }, "Quick reactions use add semantics")
    assertNoSend()
  }

  func testNativeMenuRespectsOwnMediaOnlyTombstoneAndSystemGates() throws {
    launch("menu-own")
    openMenu()
    XCTAssertTrue(menuAction("Edit").exists)
    XCTAssertTrue(menuAction("Unsend").exists)
    XCTAssertFalse(menuAction("Report").exists)
    menuAction("Edit").tap()
    waitForAction("edit")
    openMenu()
    menuAction("Unsend").tap()
    let confirmation = app.alerts["Unsend Message"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    XCTAssertFalse(actions().contains("unsend|" + targetID))
    confirmation.buttons["Unsend"].tap()
    waitForAction("unsend")
    assertNoSend()
    app.terminate()

    launch("external")
    assertExternalCardFits()
    openMenu()
    XCTAssertFalse(menuAction("Copy").exists, "An embed-only message has no message text to copy")
    XCTAssertTrue(menuAction("Reply").exists)
    XCTAssertTrue(menuAction("Report").exists)
    capture("native-media-only-menu")
    menuAction("Reply").tap()
    waitForAction("reply")
    // The quoted post's header belongs to the real RecordEmbedView Button. Tap
    // it, rather than the nested external URL card, and observe its existing
    // local NavigationPath binding. No destination/account service is mounted.
    XCTAssertEqual(state()["navigationDepth"] as? Int, 0)
    bubble().coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.045)).tap()
    waitForState { ($0["navigationDepth"] as? Int) == 1 }
    assertNoSend()
    capture("shared-record-tap-requested-local-navigation")
    app.terminate()

    for scenario in ["menu-tombstone", "menu-system"] {
      launch(scenario)
      let cell = targetCell()
      XCTAssertTrue(cell.waitForExistence(timeout: 5))
      cell.press(forDuration: 1)
      XCTAssertFalse(menuAction("More Reactions").exists)
      XCTAssertTrue(actions().isEmpty)
      capture(scenario + "-no-message-menu")
      assertNoSend()
      app.terminate()
    }
  }

  func testReactionPillHoldShowsReactorsWithoutTogglingAndTapToggles() throws {
    launch("menu-incoming")
    let pill = app.buttons["❤️, 1 reactions"].firstMatch
    XCTAssertTrue(pill.waitForExistence(timeout: 5))
    pill.press(forDuration: 0.8)
    XCTAssertTrue(app.navigationBars["Reactions"].waitForExistence(timeout: 5))
    XCTAssertTrue(actions().isEmpty, "Lifting a reaction long press must not also toggle it")
    // No authenticated lifecycle is installed; this qualifies the real sheet
    // presentation and gesture exclusivity, not account-scoped profile loading.
    capture("native-reaction-details-no-toggle")
    app.buttons["Done"].tap()
    XCTAssertTrue(pill.waitForExistence(timeout: 5))
    pill.tap()
    waitForAction("toggle:❤️")
    XCTAssertTrue(app.buttons["❤️, 2 reactions"].firstMatch.waitForExistence(timeout: 5))
    assertNoSend()
  }

  /// Drives the same accessible-action presentation route through a DEBUG
  /// fixture control. This qualifies fallback wiring, not VoiceOver's rotor.
  func testAccessibleActionSheetWiresMoreReactionsAndConfirmedUnsend() throws {
    launch("menu-incoming")
    let nativeRequestsBefore = state()["nativeMenuRequests"] as? Int
    let incoming = openAccessibleActionSheet()
    for title in ["❤️", "👍", "😂", "😲", "😢", "🔥", "More Reactions", "Reply", "Copy", "Delete for Me", "Report"] {
      XCTAssertTrue(incoming.buttons[title].exists)
    }
    XCTAssertFalse(incoming.buttons["Edit"].exists)
    XCTAssertFalse(incoming.buttons["Unsend"].exists)
    capture("accessible-native-sheet-incoming")
    incoming.buttons["More Reactions"].tap()
    waitForState { ($0["actions"] as? [String] ?? []).contains("more|" + self.targetID) }
    XCTAssertEqual(state()["nativeMenuRequests"] as? Int, nativeRequestsBefore,
      "Fallback wiring must not synthesize the touch context-menu route")
    XCTAssertEqual(productionEditor().value as? String, "local draft")
    assertNoSend()
    app.terminate()

    launch("menu-own")
    let own = openAccessibleActionSheet()
    XCTAssertTrue(own.buttons["Edit"].exists)
    XCTAssertTrue(own.buttons["Unsend"].exists)
    XCTAssertFalse(own.buttons["Report"].exists)
    own.buttons["Unsend"].tap()
    let confirmation = app.alerts["Unsend Message"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    capture("accessible-unsend-confirmation")
    confirmation.buttons["Cancel"].tap()
    wait { !confirmation.exists }
    waitForState { ($0["accessibleRequestsHandled"] as? Int) == 1 }
    XCTAssertFalse(actions().contains("unsend|" + targetID), "Cancellation must not invoke Unsend")

    openAccessibleActionSheet().buttons["Unsend"].tap()
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    confirmation.buttons["Unsend"].tap()
    waitForState { ($0["actions"] as? [String] ?? []).contains("unsend|" + self.targetID) }
    XCTAssertEqual(actions().filter { $0 == "unsend|" + targetID }.count, 1)
    XCTAssertEqual(productionEditor().value as? String, "local draft")
    assertNoSend()
    capture("accessible-unsend-confirmed-locally")
  }

  private func openAccessibleActionSheet() -> XCUIElement {
    app.buttons["chat.fixture.controls"].tap()
    let action = app.buttons["chat.fixture.accessibleActions"]
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    action.tap()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Fallback must present a real UIKit action sheet")
    XCTAssertTrue(app.staticTexts["Message Actions"].waitForExistence(timeout: 5))
    return sheet
  }

  private func launch(_ scenario: String, largerText: Bool = false) {
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    let category: UIContentSizeCategory = largerText ? .accessibilityExtraLarge : .large
    app.launchArguments = ["--messages-viewport-validation-fixture", "--chat-message-presentation=" + scenario,
      "-defaultComposerLanguage", "en", "-UIPreferredContentSizeCategoryName", category.rawValue]
    if largerText { app.launchArguments.append("--chat-message-presentation-large-text") }
    app.launch()
    XCTAssertTrue(app.staticTexts["chat.fixture.presentation"].waitForExistence(timeout: 12))
    waitForState {
      ($0["applicationContentSizeCategory"] as? String) == category.rawValue
        && ($0["contentSizeCategory"] as? String) == category.rawValue
    }
    waitForGeometry { $0.ready && $0.isSettled }
    XCTAssertTrue(targetCell().waitForExistence(timeout: 8))
  }

  private func staticText(exactLabel: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == %@", exactLabel)).firstMatch
  }

  private func targetCell() -> XCUIElement { app.cells["chat.fixture.cell." + targetID].firstMatch }
  private func bubble() -> XCUIElement { app.descendants(matching: .any)["chat.message." + targetID].firstMatch }
  private func menuAction(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch }
  private func openMenu() {
    let surface = bubble()
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    lastNativeMenuRequestCount = state()["nativeMenuRequests"] as? Int ?? 0
    surface.press(forDuration: 1)
    let appeared = menuAction("More Reactions").waitForExistence(timeout: 5)
    if !appeared {
      capture("native-message-center-hold-failed")
      let tree = XCTAttachment(string: app.debugDescription)
      tree.name = "native-message-center-hold-failed-accessibility"
      tree.lifetime = .keepAlways
      add(tree)
    }
    XCTAssertTrue(appeared, "Actual center hold must present the native message menu. State: \(state())")
  }
  private func assertNativeMenuWasUsed() {
    // UIKit may hide the underlying probe from accessibility while its menu is
    // modal. Read the persistent delegate witness after dismissal, not through
    // the modal presentation, then require a new real native configuration.
    waitForState { ($0["nativeMenuRequests"] as? Int ?? 0) > self.lastNativeMenuRequestCount }
    XCTAssertGreaterThan(state()["nativeMenuInteractions"] as? Int ?? 0, 0)
  }

  private func dragTranscript(towardOlder: Bool) {
    let collection = app.collectionViews["messages.fixture.transcript"].firstMatch
    let sample = geometry()
    let usable = (sample.collectionFrame.height - sample.footerFrame.height) / sample.collectionFrame.height
    let upper = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: CGFloat(0.08 * usable)))
    let lower = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: CGFloat(0.92 * usable)))
    let (start, end) = towardOlder ? (upper, lower) : (lower, upper)
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    waitForGeometry { $0.isSettled }
  }

  private func assertExternalCardFits(file: StaticString = #filePath, line: UInt = #line) {
    let content = staticText(exactLabel: descriptionText)
    XCTAssertTrue(content.waitForExistence(timeout: 8), "The real external card must render its description", file: file, line: line)
    let surface = bubble()
    XCTAssertTrue(surface.waitForExistence(timeout: 5), file: file, line: line)
    let frame = surface.frame
    XCTAssertLessThanOrEqual(frame.width, 281, "Production bubble width cap", file: file, line: line)
    for text in [title, descriptionText, recordBody] {
      let element = staticText(exactLabel: text)
      XCTAssertTrue(element.exists, "Expected production card content: " + text, file: file, line: line)
      XCTAssertGreaterThan(element.frame.height, 0, file: file, line: line)
      XCTAssertGreaterThanOrEqual(element.frame.minY, frame.minY - 1, file: file, line: line)
      XCTAssertLessThanOrEqual(element.frame.maxY, frame.maxY + 1,
        "The text's full laid-out rectangle must fit inside the clipped bubble", file: file, line: line)
    }
    let cell = targetCell().frame
    XCTAssertLessThanOrEqual(frame.maxY, cell.maxY - 8, "Timestamp remains outside the bubble", file: file, line: line)
    assertNoSend()
  }

  private func productionEditor() -> XCUIElement {
    let editor = app.textViews.matching(NSPredicate(format: "identifier == %@ AND label == %@",
      "chat.composer.viewporttest", "Local fixture text")).firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    return editor
  }
  private func actions() -> [String] { state()["actions"] as? [String] ?? [] }
  private func waitForAction(_ action: String) {
    waitForState { ($0["actions"] as? [String] ?? []).contains(action + "|" + self.targetID) }
    if !action.hasPrefix("toggle:") { assertNativeMenuWasUsed() }
  }
  private func assertNoSend() { XCTAssertEqual(state()["sendCount"] as? Int, 0) }
  private func assertBottomPin() {
    waitForGeometry { $0.isSettled && abs($0.legalBottom - $0.offsetY) <= 2 }
    let sample = geometry()
    XCTAssertEqual(sample.insetBottom, sample.footerFrame.height, accuracy: 1)
  }
  private func targetRow() -> Row? {
    guard let rows = state()["rows"], let data = try? JSONSerialization.data(withJSONObject: rows) else { return nil }
    return (try? JSONDecoder().decode([Row].self, from: data))?.first { $0.id == targetID }
  }
  private func state() -> [String: Any] {
    guard let raw = app.staticTexts["chat.fixture.presentation"].value as? String,
      let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return value
  }
  private func geometry() -> Geometry {
    let raw = app.staticTexts["messages.fixture.geometry"].value as? String ?? "{}"
    return (try? JSONDecoder().decode(Geometry.self, from: Data(raw.utf8))) ?? .missing
  }
  private func waitForState(_ predicate: @escaping ([String: Any]) -> Bool) {
    wait { predicate(self.state()) }
  }
  private func waitForGeometry(_ predicate: @escaping (Geometry) -> Bool) {
    wait { predicate(self.geometry()) }
  }
  private func wait(_ predicate: @escaping () -> Bool) {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { predicate() } }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
      "Presentation: \(state()); geometry: \(geometry())")
  }
  private func capture(_ label: String) {
    let image = XCTAttachment(screenshot: app.screenshot()); image.name = label; image.lifetime = .keepAlways; add(image)
    let sample = XCTAttachment(string: "\(state())\n\(geometry())"); sample.name = label + "-native-state"; sample.lifetime = .keepAlways; add(sample)
  }
  private struct Row: Decodable { let id: String, cellIdentity: String; let x: Double, y: Double, width: Double, height: Double }
  private struct Rect: Decodable { let x: Double, y: Double, width: Double, height: Double }
  private struct Geometry: Decodable {
    let ready: Bool, editorIsFirstResponder: Bool, isDragging: Bool, isTracking: Bool, isDecelerating: Bool
    let settledFor: Double, offsetY: Double, legalBottom: Double, insetBottom: Double
    let collectionFrame: Rect, footerFrame: Rect
    let anchorID: String?
    var isSettled: Bool { !isDragging && !isTracking && !isDecelerating && settledFor >= 0.25 }
    static let missing = Geometry(ready: false, editorIsFirstResponder: false, isDragging: false, isTracking: false,
      isDecelerating: false, settledFor: 0, offsetY: 0, legalBottom: 0, insetBottom: 0,
      collectionFrame: .init(x: 0, y: 0, width: 0, height: 0), footerFrame: .init(x: 0, y: 0, width: 0, height: 0), anchorID: nil)
  }
}
