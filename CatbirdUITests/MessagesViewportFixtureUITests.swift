import CoreGraphics
import Foundation
import XCTest

/// Native source preparation: these selectors require the separately integrated
/// DEBUG route, a fresh disposable simulator container, and an execution grant.
/// Metadata is supplied locally; resolver/network/record-cache gates are excluded.
@MainActor
final class MessagesViewportFixtureUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testLongTranscriptComposerGlassAndKeyboardGrowth() throws {
    let app = try launchFixture()
    let original = try settled(app)
    assertFooterReservation(original)
    XCTAssertGreaterThan(original.contentHeight, original.collectionFrame.height - original.insetBottom)
    XCTAssertEqual(original.offsetY, original.legalBottom, accuracy: original.epsilon)
    capture("Long transcript, cyan backdrop, real composer glass", app: app)

    app.buttons["messages.fixture.backdrop"].tap()
    let coral = try waitForSample(app) { $0.backdrop == "coral" && $0.isSettled }
    XCTAssertEqual(coral.footerFrame.height, original.footerFrame.height, accuracy: coral.epsilon)
    XCTAssertEqual(coral.collectionFrame.height, original.collectionFrame.height, accuracy: coral.epsilon)
    capture("Same composer glass over contrasting coral backdrop", app: app)

    let editor = app.textViews["chat.composer.textInput.viewporttest"].firstMatch
    XCTAssertTrue(editor.isHittable)
    editor.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Requires a real software keyboard")
    let focused = try waitForSample(app) { $0.editorIsFirstResponder && $0.isSettled }
    let text = (1...8).map { "Local keyboard line \($0) wraps inside the actual editor." }.joined(separator: "\n")
    editor.typeText(text)
    let grown = try waitForSample(app) {
      $0.editorTextCount == text.count && $0.editorIsFirstResponder && $0.isSettled
    }
    assertFooterReservation(grown)
    XCTAssertGreaterThan(grown.editorFrame.height, focused.editorFrame.height + grown.epsilon,
      "Typing must grow the production TextEditor rather than a surrogate footer")
    XCTAssertGreaterThan(grown.footerFrame.height, focused.footerFrame.height + grown.epsilon)
    XCTAssertLessThan(grown.collectionFrame.height, original.collectionFrame.height - grown.epsilon)
    XCTAssertLessThanOrEqual(grown.collectionFrame.maxY, Double(app.keyboards.firstMatch.frame.minY) + grown.epsilon)
    XCTAssertEqual(grown.offsetY, grown.legalBottom, accuracy: grown.epsilon)
    assertSendingBlocked(app, sample: grown)
    capture("Actual multiline TextEditor and software keyboard", app: app)

    app.buttons["messages.fixture.dismissKeyboard"].tap()
    let dismissed = try waitForSample(app) {
      !$0.editorIsFirstResponder && $0.isSettled
        && abs($0.collectionFrame.height - original.collectionFrame.height) <= $0.epsilon
    }
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertEqual(dismissed.editorTextCount, text.count)
    XCTAssertEqual(dismissed.offsetY, dismissed.legalBottom, accuracy: dismissed.epsilon)
    assertFooterReservation(dismissed)
    assertSendingBlocked(app, sample: dismissed)
    capture("Keyboard dismissed naturally, local text retained", app: app)
  }

  func testLongTranscriptHeldTopAndBottomElasticDragsSettleNaturally() throws {
    let app = try launchFixture()
    try moveToEdge(.top, app: app)
    try resetDragWitnesses(app)
    holdElasticDrag(.top, app: app)
    let top = try waitForSample(app) { $0.topWitness != nil && $0.topHeldSeconds >= 0.2 }
    let topWitness = try XCTUnwrap(top.topWitness)
    XCTAssertTrue(topWitness.isDragging)
    XCTAssertLessThan(topWitness.offsetY, topWitness.legalTop - top.epsilon)
    capture("Long top: recorded while finger held, screenshot after release", app: app)
    let topSettled = try settled(app)
    XCTAssertEqual(topSettled.offsetY, topSettled.legalTop, accuracy: topSettled.epsilon)
    XCTAssertGreaterThan(topSettled.rowsUnderFooter, 0, "Actual colored native rows must continue beneath glass")

    try moveToEdge(.bottom, app: app)
    try resetDragWitnesses(app)
    holdElasticDrag(.bottom, app: app)
    let bottom = try waitForSample(app) { $0.bottomWitness != nil && $0.bottomHeldSeconds >= 0.2 }
    let bottomWitness = try XCTUnwrap(bottom.bottomWitness)
    XCTAssertTrue(bottomWitness.isDragging)
    XCTAssertGreaterThan(bottomWitness.offsetY, bottomWitness.legalBottom + bottom.epsilon)
    capture("Long bottom: recorded while finger held, screenshot after release", app: app)
    let bottomSettled = try settled(app)
    XCTAssertEqual(bottomSettled.offsetY, bottomSettled.legalBottom, accuracy: bottomSettled.epsilon)
    assertFooterReservation(bottomSettled)
    assertSendingBlocked(app, sample: bottomSettled)
  }

  func testShortTranscriptBouncesAndRealKeyboardKeepsOneFooterReservation() throws {
    let app = try launchFixture(short: true)
    let initial = try settled(app)
    XCTAssertEqual(initial.messageCount, 2)
    XCTAssertLessThan(initial.contentHeight, initial.collectionFrame.height - initial.insetBottom)
    XCTAssertEqual(initial.legalTop, initial.legalBottom, accuracy: initial.epsilon)
    assertFooterReservation(initial)
    capture("Short transcript beneath real glass", app: app)

    try resetDragWitnesses(app)
    holdElasticDrag(.top, app: app)
    let top = try waitForSample(app) { $0.topWitness != nil && $0.topHeldSeconds >= 0.2 }
    XCTAssertTrue(try XCTUnwrap(top.topWitness).isDragging)
    XCTAssertLessThan(try XCTUnwrap(top.topWitness).offsetY, top.legalTop - top.epsilon)
    _ = try settled(app)
    try resetDragWitnesses(app)
    holdElasticDrag(.bottom, app: app)
    let bottom = try waitForSample(app) { $0.bottomWitness != nil && $0.bottomHeldSeconds >= 0.2 }
    XCTAssertTrue(try XCTUnwrap(bottom.bottomWitness).isDragging)
    XCTAssertGreaterThan(try XCTUnwrap(bottom.bottomWitness).offsetY, bottom.legalBottom + bottom.epsilon)
    let released = try settled(app)
    XCTAssertEqual(released.offsetY, released.legalTop, accuracy: released.epsilon)
    capture("Short bottom held-drag evidence, native spring settled", app: app)

    let editor = app.textViews["chat.composer.textInput.viewporttest"].firstMatch
    editor.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let text = "Local short chat\nSecond line\nThird line\nFourth line"
    editor.typeText(text)
    let keyboard = try waitForSample(app) {
      $0.editorIsFirstResponder && $0.editorTextCount == text.count && $0.isSettled
    }
    assertFooterReservation(keyboard)
    XCTAssertLessThan(keyboard.collectionFrame.height, initial.collectionFrame.height - keyboard.epsilon)
    // The legal range is derived from current UIKit content and viewport, even
    // if keyboard avoidance makes this formerly short transcript scrollable.
    XCTAssertEqual(keyboard.legalBottom, max(keyboard.legalTop,
      keyboard.contentHeight - keyboard.collectionFrame.height + keyboard.adjustedInsetBottom),
      accuracy: keyboard.epsilon)
    XCTAssertEqual(keyboard.offsetY, keyboard.legalBottom, accuracy: keyboard.epsilon)
    assertSendingBlocked(app, sample: keyboard)
    capture("Short transcript with real keyboard and local text", app: app)
    app.buttons["messages.fixture.dismissKeyboard"].tap()
    let restored = try waitForSample(app) {
      !$0.editorIsFirstResponder && $0.isSettled
        && abs($0.collectionFrame.height - initial.collectionFrame.height) <= $0.epsilon
    }
    XCTAssertEqual(restored.messageCount, 2)
    XCTAssertEqual(restored.editorTextCount, text.count)
    XCTAssertEqual(restored.offsetY, restored.legalBottom, accuracy: restored.epsilon)
    assertFooterReservation(restored)
    assertSendingBlocked(app, sample: restored)
  }

  func testLateSuppliedLinkMetadataKeepsTheVisibleReadingAnchor() throws {
    let app = try launchFixture()
    let collection = app.collectionViews["messages.fixture.transcript"].firstMatch
    collection.swipeDown(velocity: .slow)
    let before = try waitForSample(app) {
      $0.isSettled && $0.legalBottom - $0.offsetY > $0.footerFrame.height && $0.anchorID != nil
    }
    let anchorID = try XCTUnwrap(before.anchorID)
    let anchorY = try XCTUnwrap(before.anchorY)
    let height = try XCTUnwrap(before.anchorHeight)
    XCTAssertGreaterThan(before.rowsUnderFooter, 0)
    capture("Reading older local row before supplied metadata reconfigure", app: app)
    app.buttons["messages.fixture.grow"].tap()
    let after = try waitForSample(app) {
      $0.localRevision == 1 && $0.isSettled && ($0.anchorHeight ?? 0) > height + $0.epsilon
        && $0.contentHeight > before.contentHeight + $0.epsilon
    }
    XCTAssertEqual(after.messageCount, before.messageCount)
    XCTAssertEqual(after.anchorID, anchorID)
    XCTAssertEqual(try XCTUnwrap(after.anchorY), anchorY, accuracy: after.epsilon)
    XCTAssertGreaterThan(after.legalBottom - after.offsetY, after.footerFrame.height)
    assertFooterReservation(after)
    assertSendingBlocked(app, sample: after)
    capture("Actual bubble and known local link resized, reading origin retained", app: app)
  }

  private enum Edge { case top, bottom }

  private func launchFixture(short: Bool = false) throws -> XCUIApplication {
    let app = XCUIApplication()
    // This is the launch-only argument domain, never a persistent defaults edit.
    app.launchArguments = ["--messages-viewport-validation-fixture", "-defaultComposerLanguage", "en"]
      + (short ? ["--messages-viewport-short"] : [])
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["messages.fixture.geometry"].firstMatch.waitForExistence(timeout: 8))
    let sample = try waitForSample(app) { $0.ready && $0.isSettled }
    let sends = productionSendButtons(app)
    let send = sends.firstMatch
    XCTAssertTrue(send.waitForExistence(timeout: 5), "The real production Send button must exist")
    XCTAssertEqual(sends.count, 1, "Exactly one real production Send button must exist")
    assertSendingBlocked(app, sample: sample)
    return app
  }

  private func moveToEdge(_ edge: Edge, app: XCUIApplication) throws {
    let collection = app.collectionViews["messages.fixture.transcript"].firstMatch
    for _ in 0..<24 {
      let sample = try settled(app)
      let target = edge == .top ? sample.legalTop : sample.legalBottom
      if abs(sample.offsetY - target) <= sample.epsilon { return }
      if edge == .top { collection.swipeDown(velocity: .fast) }
      else { collection.swipeUp(velocity: .fast) }
    }
    XCTFail("Native gestures did not reach the requested legal edge")
    throw FixtureError.edgeNotReached
  }

  private func resetDragWitnesses(_ app: XCUIApplication) throws {
    let prior = try readSample(app).resetSequence
    app.buttons["messages.fixture.resetDrags"].tap()
    _ = try waitForSample(app) {
      $0.resetSequence == prior + 1 && $0.topWitness == nil && $0.bottomWitness == nil && $0.isSettled
    }
  }

  private func holdElasticDrag(_ edge: Edge, app: XCUIApplication) {
    let collection = app.collectionViews["messages.fixture.transcript"].firstMatch
    // Use the actual unobscured transcript height, keeping both coordinates
    // above the measured composer. The right gutter avoids bubble long-press.
    guard let sample = try? readSample(app) else { XCTFail("Missing native sample"); return }
    let usableFraction = (sample.collectionFrame.height - sample.footerFrame.height) / sample.collectionFrame.height
    let upper = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: CGFloat(0.20 * usableFraction)))
    let lower = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: CGFloat(0.80 * usableFraction)))
    let start = edge == .top ? upper : lower
    let end = edge == .top ? lower : upper
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
    // XCTest returns after releasing the finger. The app's display-link probe
    // retains the offset/legal-bound/isDragging witness from the actual hold.
  }

  private func settled(_ app: XCUIApplication) throws -> Sample {
    try waitForSample(app) { $0.ready && $0.isSettled }
  }

  private func waitForSample(_ app: XCUIApplication, timeout: TimeInterval = 8,
    _ predicate: (Sample) -> Bool) throws -> Sample {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let sample = try? readSample(app), predicate(sample) { return sample }
      // The UI test runs in a separate process; this does not block UIKit's
      // display link, software keyboard, drag recognizer or native spring.
      Thread.sleep(forTimeInterval: 0.08)
    } while Date() < deadline
    capture("Failed native geometry predicate", app: app)
    XCTFail("Timed out waiting for native geometry: \(rawSample(app) ?? "missing probe")")
    throw FixtureError.sampleTimedOut
  }

  private func rawSample(_ app: XCUIApplication) -> String? {
    let probe = app.descendants(matching: .any)["messages.fixture.geometry"].firstMatch
    guard probe.exists else { return nil }
    return probe.value as? String
  }
  private func readSample(_ app: XCUIApplication) throws -> Sample {
    guard let raw = rawSample(app) else { throw FixtureError.sampleMissing }
    return try JSONDecoder().decode(Sample.self, from: Data(raw.utf8))
  }

  private func assertFooterReservation(_ sample: Sample, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(sample.footerFrame.height, 0, file: file, line: line)
    XCTAssertTrue(sample.bounces, file: file, line: line)
    XCTAssertTrue(sample.alwaysBounceVertical, file: file, line: line)
    XCTAssertFalse(sample.adjustsInsetAutomatically, file: file, line: line)
    XCTAssertEqual(sample.insetBottom, sample.footerFrame.height, accuracy: sample.epsilon, file: file, line: line)
    XCTAssertEqual(sample.adjustedInsetBottom, sample.footerFrame.height, accuracy: sample.epsilon, file: file, line: line)
    XCTAssertEqual(sample.collectionFrame.maxY, sample.footerFrame.maxY, accuracy: sample.epsilon, file: file, line: line)
    XCTAssertEqual(sample.collectionFrame.maxY - sample.adjustedInsetBottom, sample.footerFrame.y,
      accuracy: sample.epsilon, file: file, line: line)
    XCTAssertGreaterThanOrEqual(sample.offsetY, sample.legalTop - sample.epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(sample.offsetY, sample.legalBottom + sample.epsilon, file: file, line: line)
  }

  private func productionSendButtons(_ app: XCUIApplication) -> XCUIElementQuery {
    app.buttons.matching(NSPredicate(
      format: "identifier == %@ AND label == %@",
      "chat.composer.viewporttest", "Send message"
    ))
  }

  private func assertSendingBlocked(_ app: XCUIApplication, sample: Sample,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(sample.sendCallbackCount, 0, file: file, line: line)
    let sends = productionSendButtons(app)
    let send = sends.firstMatch
    XCTAssertEqual(sends.count, 1, "Exactly one real production Send button must remain present", file: file, line: line)
    XCTAssertTrue(send.exists, "The real production Send button must remain present", file: file, line: line)
    XCTAssertFalse(send.isEnabled, "Production Send must remain disabled locally", file: file, line: line)
  }

  private func capture(_ name: String, app: XCUIApplication) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let geometry = XCTAttachment(string: rawSample(app) ?? "No native geometry sample")
    geometry.name = name + " — UIKit geometry and held-drag witnesses"
    geometry.lifetime = .keepAlways
    add(geometry)
  }

  private enum FixtureError: Error { case edgeNotReached, sampleTimedOut, sampleMissing }

  private struct Rect: Decodable {
    let x: Double, y: Double, width: Double, height: Double
    var maxY: Double { y + height }
  }
  private struct Witness: Decodable {
    let offsetY: Double, legalTop: Double, legalBottom: Double, timestamp: Double
    let isDragging: Bool
  }
  private struct Sample: Decodable {
    let ready: Bool
    let sampleCount: Int, resetSequence: Int, messageCount: Int, localRevision: Int, sendCallbackCount: Int
    let backdrop: String
    let scale: Double
    let collectionFrame: Rect, footerFrame: Rect, editorFrame: Rect
    let editorIsFirstResponder: Bool
    let editorTextCount: Int
    let contentHeight: Double, offsetY: Double, legalTop: Double, legalBottom: Double
    let insetBottom: Double, adjustedInsetBottom: Double
    let bounces: Bool, alwaysBounceVertical: Bool, adjustsInsetAutomatically: Bool
    let isDragging: Bool, isTracking: Bool, isDecelerating: Bool
    let settledFor: Double
    let anchorID: String?
    let anchorY: Double?, anchorHeight: Double?
    let rowsUnderFooter: Int
    let topWitness: Witness?, bottomWitness: Witness?
    let topHeldSeconds: Double, bottomHeldSeconds: Double
    var epsilon: Double { 2 / scale }
    var isSettled: Bool { !isDragging && !isTracking && !isDecelerating && settledFor >= 0.25 }
  }
}
