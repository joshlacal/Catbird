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

    let editor = productionEditor(app)
    editor.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Requires a real software keyboard")
    let focused = try waitForSample(app) { $0.editorIsFirstResponder && $0.isSettled }
    let text = "local\nkeyboard\nlines\ngrow\nthe\nactual\neditor"
    typeOnSoftwareKeyboard(text, app: app)
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

    let editor = productionEditor(app)
    editor.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let text = "local short chat\nsecond line\nthird line\nfourth line"
    typeOnSoftwareKeyboard(text, app: app)
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
    // A gutter control and center drag start from separate, identical fresh
    // fixtures. The control never substitutes for the required center scroll.
    let control = try launchFixture()
    let controlInitial = try settled(control)
    let gutterTrace = try recordDiagnosticDrag(.gutter, app: control)
    let controlAfter = try settled(control)
    assertDiagnosticIdentity(gutterTrace, before: controlInitial, after: controlAfter)
    assertSendingBlocked(control, sample: controlAfter)
    capture("Matched gutter native drag — passive recognition control", app: control, includeGestureTrace: true)

    let app = try launchFixture()
    let centerInitial = try settled(app)
    assertUniformFreshLaunches(controlInitial, centerInitial)
    let centerTrace = try recordDiagnosticDrag(.center, app: app)
    let centerAfter = try settled(app)
    assertMatchingDragPlans(gutterTrace, centerTrace, epsilon: centerInitial.epsilon)
    assertDiagnosticIdentity(centerTrace, before: centerInitial, after: centerAfter)
    assertSendingBlocked(app, sample: centerAfter)
    // Preserve the observation even when the unchanged reading-away-from-bottom
    // predicate below fails. No offset or gesture recognizer is changed by the probe.
    capture("Matched center native drag — passive recognition evidence", app: app, includeGestureTrace: true)
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

  func testComposerAlignmentWithRealKeyboardAndMultilineDraft() throws {
    let app = try launchFixture(alignmentScenario: "empty")
    let empty = try settled(app)
    capture("Alignment: empty composer, keyboard hidden", app: app)
    assertSingleLineCenteredInCapsule(app, sample: empty)
    assertFooterReservation(empty)
    XCTAssertFalse(productionSendButtons(app).firstMatch.isEnabled)

    productionEditor(app).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Requires a real software keyboard")
    let focused = try waitForSample(app) {
      $0.editorIsFirstResponder && $0.editorTextCount == 0 && $0.isSettled
    }
    capture("Alignment: empty composer, software keyboard open", app: app)
    assertSingleLineCenteredInCapsule(app, sample: focused)
    assertFooterReservation(focused)

    typeExactLowercaseOnSoftwareKeyboard("g", app: app)
    let single = try waitForSample(app) {
      $0.editorTextCount == 1 && $0.editorIsFirstResponder && $0.isSettled
    }
    capture("Alignment: exact lowercase g, software keyboard open", app: app)
    XCTAssertEqual(productionEditor(app).value as? String, "g")
    XCTAssertTrue(productionSendButtons(app).firstMatch.isEnabled)
    assertSingleLineCenteredInCapsule(app, sample: single)
    assertFooterReservation(single)
    let keyboardOpenBottomInset = sendBottomInset(app, sample: single)

    app.buttons["messages.fixture.dismissKeyboard"].tap()
    let dismissed = try waitForSample(app) {
      !$0.editorIsFirstResponder && $0.editorTextCount == 1 && $0.isSettled
    }
    capture("Alignment: exact lowercase g, keyboard dismissed", app: app)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertEqual(productionEditor(app).value as? String, "g")
    assertSingleLineCenteredInCapsule(app, sample: dismissed)
    assertFooterReservation(dismissed)
    let keyboardClosedBottomInset = sendBottomInset(app, sample: dismissed)

    // A generic element-center tap can place the insertion point before "g".
    // Tap just after the measured retained end caret, within the native editor.
    let endCaret = try XCTUnwrap(dismissed.caretFrame)
    let endTapX = min(endCaret.maxX + 4, dismissed.editorFrame.maxX - 1)
    XCTAssertGreaterThan(endTapX, endCaret.x)
    app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: CGFloat(endTapX), dy: CGFloat(endCaret.midY))).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    _ = try waitForSample(app) {
      $0.editorIsFirstResponder && $0.editorTextCount == 1 && $0.isSettled
        && abs(($0.caretFrame?.x ?? -.infinity) - endCaret.x) <= $0.epsilon
    }
    let suffix = "\nsecond\nthird"
    typeExactLowercaseOnSoftwareKeyboard(suffix, app: app)
    let multiline = try waitForSample(app) {
      $0.editorTextCount == 1 + suffix.count && $0.editorIsFirstResponder
        && $0.editorFrame.height > single.editorFrame.height + $0.epsilon && $0.isSettled
    }
    capture("Alignment: multiline draft, software keyboard open", app: app)
    XCTAssertEqual(productionEditor(app).value as? String, "g" + suffix)
    assertSendRemainsInBottomRow(app, sample: multiline, expectedBottomInset: keyboardOpenBottomInset)
    assertFooterReservation(multiline)

    app.buttons["messages.fixture.dismissKeyboard"].tap()
    let retained = try waitForSample(app) {
      !$0.editorIsFirstResponder && $0.editorTextCount == 1 + suffix.count && $0.isSettled
    }
    capture("Alignment: multiline draft, keyboard dismissed", app: app)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertEqual(productionEditor(app).value as? String, "g" + suffix)
    assertSendRemainsInBottomRow(app, sample: retained, expectedBottomInset: keyboardClosedBottomInset)
    assertFooterReservation(retained)
  }

  /// Capture the same actual lowercase draft for baseline/revised app binaries.
  /// This records geometry without applying the revised capsule-centering oracle.
  func testCaptureComposerGReferenceWithRealKeyboard() throws {
    let app = try launchFixture(alignmentScenario: "empty")
    productionEditor(app).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    _ = try waitForSample(app) { $0.editorIsFirstResponder && $0.editorTextCount == 0 && $0.isSettled }
    typeExactLowercaseOnSoftwareKeyboard("g", app: app)
    let opened = try waitForSample(app) {
      $0.editorIsFirstResponder && $0.editorTextCount == 1 && $0.isSettled
    }
    captureComposerReference("Reference: exact lowercase g, software keyboard open", app: app, sample: opened)
    XCTAssertEqual(productionEditor(app).value as? String, "g")
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    XCTAssertEqual(opened.sendCallbackCount, 0)

    app.buttons["messages.fixture.dismissKeyboard"].tap()
    let closed = try waitForSample(app) {
      !$0.editorIsFirstResponder && $0.editorTextCount == 1 && $0.isSettled
    }
    captureComposerReference("Reference: exact lowercase g, keyboard dismissed", app: app, sample: closed)
    XCTAssertEqual(productionEditor(app).value as? String, "g")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertEqual(closed.sendCallbackCount, 0)
  }

  private func captureComposerReference(_ name: String, app: XCUIApplication, sample: Sample) {
    capture(name, app: app)
    let send = productionSendButtons(app).firstMatch.frame
    let attachment = XCTAttachment(string:
      "Send accessibility frame: \(send)\nFooter: \(sample.footerFrame)\nSend minus footer midpoint: \(Double(send.midY) - sample.footerFrame.midY) points")
    attachment.name = name + " — Send accessibility geometry"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testComposerLargerTextFitsNativeEditor() throws {
    let app = try launchFixture(alignmentScenario: "accessibility3")
    let sample = try waitForSample(app) {
      $0.editorTextCount == 2 && $0.caretFrame != nil && $0.isSettled
    }
    capture("Independent AX3: native editor, caret, text and insets", app: app)
    XCTAssertEqual(productionEditor(app).value as? String, "hi")
    assertComposerBounds(app, sample: sample)
    assertFooterReservation(sample)
    assertEditorContainsTextAndCaret(sample)
  }

  func testComposerAlignmentSeededCounterAttachmentAndLargerText() throws {
    var normalCaretHeight = 0.0
    var normalFontLineHeight = 0.0
    var normalBottomInset = 0.0
    var normalKeyboardOpenBottomInset = 0.0
    for scenario in ["hi", "multiline", "counter950", "attached", "accessibility3"] {
      let app = try launchFixture(alignmentScenario: scenario)
      let expectedCount = scenario == "counter950" ? 950
        : scenario == "multiline" ? "one\nsecond\nthird".count : 2
      let sample = try waitForSample(app) {
        $0.editorTextCount == expectedCount && $0.caretFrame != nil && $0.isSettled
      }
      capture("Alignment seeded state: " + scenario, app: app)
      assertComposerBounds(app, sample: sample)
      assertFooterReservation(sample)
      XCTAssertTrue(productionSendButtons(app).firstMatch.isEnabled)
      if scenario == "hi" {
        normalCaretHeight = try XCTUnwrap(sample.caretFrame).height
        normalFontLineHeight = try XCTUnwrap(sample.editorFontLineHeight)
        normalBottomInset = sendBottomInset(app, sample: sample)
        assertSingleLineCenteredInCapsule(app, sample: sample)
      } else {
        // A preview, counter, or taller text changes the capsule's height.
        // Check the bottom row and touch target, not centering in the whole capsule.
        assertSendRemainsInBottomRow(app, sample: sample, expectedBottomInset: normalBottomInset)
        if scenario == "counter950" {
          XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "950")).firstMatch.exists)
        } else if scenario == "attached" {
          XCTAssertTrue(app.buttons["Remove post"].exists)
        } else if scenario == "accessibility3" {
          XCTAssertGreaterThan(try XCTUnwrap(sample.caretFrame).height, normalCaretHeight * 1.2,
            "The larger-text fixture must actually enlarge the native text, not only pass a launch flag")
          XCTAssertGreaterThan(try XCTUnwrap(sample.editorFontLineHeight), normalFontLineHeight * 1.2)
          assertEditorContainsTextAndCaret(sample)
        }
      }
      if scenario == "hi" || scenario == "accessibility3" {
        XCTAssertEqual(productionEditor(app).value as? String, "hi")
        productionEditor(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let opened = try waitForSample(app) {
          $0.editorIsFirstResponder && $0.editorTextCount == 2 && $0.isSettled
        }
        capture("Alignment seeded state: " + scenario + ", software keyboard open", app: app)
        XCTAssertEqual(productionEditor(app).value as? String, "hi")
        assertFooterReservation(opened)
        if scenario == "hi" {
          normalKeyboardOpenBottomInset = sendBottomInset(app, sample: opened)
          assertSingleLineCenteredInCapsule(app, sample: opened)
        } else {
          assertSendRemainsInBottomRow(app, sample: opened, expectedBottomInset: normalKeyboardOpenBottomInset)
          assertEditorContainsTextAndCaret(opened)
        }

        app.buttons["messages.fixture.dismissKeyboard"].tap()
        let closed = try waitForSample(app) {
          !$0.editorIsFirstResponder && $0.editorTextCount == 2 && $0.isSettled
        }
        capture("Alignment seeded state: " + scenario + ", keyboard dismissed", app: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(productionEditor(app).value as? String, "hi")
        assertFooterReservation(closed)
        if scenario == "hi" {
          assertSingleLineCenteredInCapsule(app, sample: closed)
        } else {
          assertSendRemainsInBottomRow(app, sample: closed, expectedBottomInset: normalBottomInset)
          assertEditorContainsTextAndCaret(closed)
        }
      }
      app.terminate()
    }
  }

  private func assertComposerBounds(_ app: XCUIApplication, sample: Sample,
    file: StaticString = #filePath, line: UInt = #line) {
    let send = productionSendButtons(app).firstMatch.frame
    let epsilon = CGFloat(sample.epsilon)
    XCTAssertGreaterThanOrEqual(send.width, 44 - epsilon, file: file, line: line)
    XCTAssertGreaterThanOrEqual(send.height, 44 - epsilon, file: file, line: line)
    XCTAssertGreaterThanOrEqual(send.minY, CGFloat(sample.footerFrame.y) - epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(send.maxY, CGFloat(sample.footerFrame.maxY) + epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(CGFloat(sample.editorFrame.maxX), send.minX + epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(sample.editorFrame.height, 120 + sample.epsilon, file: file, line: line)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(send), file: file, line: line)
    XCTAssertEqual(sample.sendCallbackCount, 0, "Geometry checks must not invoke even the local Send callback",
      file: file, line: line)
  }

  private func assertSingleLineCenteredInCapsule(_ app: XCUIApplication, sample: Sample,
    file: StaticString = #filePath, line: UInt = #line) {
    assertComposerBounds(app, sample: sample, file: file, line: line)
    let send = productionSendButtons(app).firstMatch.frame
    // These calls use only single-line fixtures without a post preview or counter.
    // The glass has symmetric outer padding, so its center equals the measured footer center.
    // The 30-point circle is centered inside this 44-point accessibility/touch target.
    let delta = Double(send.midY) - sample.footerFrame.midY
    print("Composer capsule alignment: sendFrame=\(send), footer=\(sample.footerFrame), delta=\(delta)")
    XCTAssertEqual(Double(send.midY), sample.footerFrame.midY, accuracy: 1.5,
      "Single-line Send must be centered in the composer capsule within 1.5 points", file: file, line: line)
    XCTAssertEqual(sample.editorFrame.midY, sample.footerFrame.midY, accuracy: 1.5,
      "Centering Send alone must not leave the native editor above the capsule center", file: file, line: line)
    guard let caret = sample.caretFrame else {
      XCTFail("The single-line native caret must be measured", file: file, line: line)
      return
    }
    XCTAssertEqual(caret.midY, sample.footerFrame.midY, accuracy: 1.5,
      "The native single-line caret must be centered in the capsule within 1.5 points", file: file, line: line)
    assertEditorContainsTextAndCaret(sample, file: file, line: line)
  }

  private func assertEditorContainsTextAndCaret(_ sample: Sample,
    file: StaticString = #filePath, line: UInt = #line) {
    print("Native editor: frame=\(sample.editorFrame), caret=\(String(describing: sample.caretFrame)), text=\(String(describing: sample.editorTextBounds)), fontLineHeight=\(String(describing: sample.editorFontLineHeight)), textContainerInset=\(String(describing: sample.editorTextContainerInset)), contentInset=\(String(describing: sample.editorContentInset)), contentSize=\(String(describing: sample.editorContentSize)), contentOffset=\(String(describing: sample.editorContentOffset))")
    guard let caret = sample.caretFrame, let fontLineHeight = sample.editorFontLineHeight else {
      XCTFail("Actual native caret and font line height must be available", file: file, line: line)
      return
    }
    XCTAssertGreaterThan(fontLineHeight, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(sample.editorFrame.height, fontLineHeight - sample.epsilon,
      "The native editor must fit one full font line", file: file, line: line)
    assertContained(sample.editorFrame, in: sample.footerFrame, epsilon: sample.epsilon,
      label: "Native editor in composer", file: file, line: line)
    assertContained(caret, in: sample.editorFrame, epsilon: sample.epsilon,
      label: "Native caret in editor", file: file, line: line)
    if sample.editorTextCount > 0 {
      guard let textBounds = sample.editorTextBounds else {
        XCTFail("Nonempty text must expose actual UITextInput text rectangles", file: file, line: line)
        return
      }
      assertContained(textBounds, in: sample.editorFrame, epsilon: sample.epsilon,
        label: "Native text in editor", file: file, line: line)
    }
  }

  private func assertContained(_ inner: Rect, in outer: Rect, epsilon: Double, label: String,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThanOrEqual(inner.x, outer.x - epsilon, label + " left edge", file: file, line: line)
    XCTAssertLessThanOrEqual(inner.maxX, outer.maxX + epsilon, label + " right edge", file: file, line: line)
    XCTAssertGreaterThanOrEqual(inner.y, outer.y - epsilon, label + " top edge", file: file, line: line)
    XCTAssertLessThanOrEqual(inner.maxY, outer.maxY + epsilon, label + " bottom edge", file: file, line: line)
  }

  private func sendBottomInset(_ app: XCUIApplication, sample: Sample) -> Double {
    sample.footerFrame.maxY - Double(productionSendButtons(app).firstMatch.frame.maxY)
  }

  private func assertSendRemainsInBottomRow(_ app: XCUIApplication, sample: Sample, expectedBottomInset: Double,
    file: StaticString = #filePath, line: UInt = #line) {
    assertComposerBounds(app, sample: sample, file: file, line: line)
    let actual = sendBottomInset(app, sample: sample)
    print("Composer bottom row: sendFrame=\(productionSendButtons(app).firstMatch.frame), footer=\(sample.footerFrame), bottomInset=\(actual)")
    XCTAssertEqual(actual, expectedBottomInset, accuracy: 1.5,
      "Growing content must retain the Send target's bottom inset", file: file, line: line)
  }

  private enum Edge { case top, bottom }
  private enum DragSurface: String { case center, gutter }

  private func launchFixture(short: Bool = false, alignmentScenario: String? = nil) throws -> XCUIApplication {
    let app = XCUIApplication()
    // This is the launch-only argument domain, never a persistent defaults edit.
    app.launchArguments = ["--messages-viewport-validation-fixture", "-defaultComposerLanguage", "en"]
      + (short ? ["--messages-viewport-short"] : [])
    if let alignmentScenario {
      app.launchArguments += ["--messages-composer-alignment", "--messages-composer-scenario=" + alignmentScenario]
    }
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["messages.fixture.geometry"].firstMatch.waitForExistence(timeout: 8))
    let sample = try waitForSample(app) { $0.ready && $0.isSettled }
    let sends = productionSendButtons(app)
    let send = sends.firstMatch
    XCTAssertTrue(send.waitForExistence(timeout: 5), "The real production Send button must exist")
    XCTAssertEqual(sends.count, 1, "Exactly one real production Send button must exist")
    if alignmentScenario == nil {
      assertSendingBlocked(app, sample: sample)
    } else {
      XCTAssertEqual(sample.sendCallbackCount, 0)
    }
    return app
  }

  private func moveToEdge(_ edge: Edge, app: XCUIApplication) throws {
    let collection = app.collectionViews["messages.fixture.transcript"].firstMatch
    for _ in 0..<48 {
      let sample = try settled(app)
      let target = edge == .top ? sample.legalTop : sample.legalBottom
      if abs(sample.offsetY - target) <= sample.epsilon { return }
      // Use the gesture shape the passive center/gutter traces proved scrolls
      // natively. Instant, very fast synthesized drags (and .fast swipes) that
      // start on transcript content register no pan on the iOS 27 simulator,
      // and at the right edge the interactive scroll indicator claims the
      // touch once its knob sits under it. A short hold keeps travel exact.
      let usableFraction = (sample.collectionFrame.height - sample.footerFrame.height) / sample.collectionFrame.height
      let upper = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: CGFloat(0.08 * usableFraction)))
      let lower = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: CGFloat(0.92 * usableFraction)))
      let (start, end) = edge == .top ? (upper, lower) : (lower, upper)
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    XCTFail("Native gestures did not reach the requested legal edge: \(rawSample(app) ?? "missing probe")")
    throw FixtureError.edgeNotReached
  }

  /// Types with the real software keyboard's keys. XCUITest `typeText` sends
  /// hardware key events on the iOS 27 simulator, which collapses the software
  /// keyboard and invalidates every keyboard-avoidance assertion.
  private func typeOnSoftwareKeyboard(_ text: String, app: XCUIApplication) {
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Requires a real software keyboard")
    for character in text {
      let key: XCUIElement
      switch character {
      case "\n": key = keyboard.buttons["Return"].exists ? keyboard.buttons["Return"] : keyboard.keys["return"]
      case " ": key = keyboard.keys["space"]
      default:
        // Auto-capitalization relabels letter keys (e.g. "L" at sentence start).
        let lower = keyboard.keys[String(character)]
        key = lower.exists ? lower : keyboard.keys[String(character).uppercased()]
      }
      XCTAssertTrue(key.waitForExistence(timeout: 2), "Missing software key for \(character.debugDescription)")
      key.tap()
    }
    XCTAssertTrue(keyboard.exists, "The software keyboard must remain presented after typing")
  }

  /// Unlike the general viewport helper, preserve lowercase even at sentence start.
  /// This reproduces the reported "g" through actual software keys, without hardware events.
  private func typeExactLowercaseOnSoftwareKeyboard(_ text: String, app: XCUIApplication) {
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Requires a real software keyboard")
    for character in text {
      if character == "\n" || character == " " {
        typeOnSoftwareKeyboard(String(character), app: app)
        continue
      }
      let letter = String(character)
      let key = keyboard.keys.matching(NSPredicate(format: "label == %@", letter)).firstMatch
      let uppercaseKey = keyboard.keys.matching(NSPredicate(format: "label == %@", letter.uppercased())).firstMatch
      if !key.exists && uppercaseKey.exists {
        let shiftPredicate = NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "shift", "shift")
        let shiftButton = keyboard.buttons.matching(shiftPredicate).firstMatch
        let shift = shiftButton.exists ? shiftButton : keyboard.keys.matching(shiftPredicate).firstMatch
        XCTAssertTrue(shift.waitForExistence(timeout: 2), "Requires the actual software Shift control")
        XCTAssertTrue(shift.isHittable)
        shift.tap()
      }
      XCTAssertTrue(key.waitForExistence(timeout: 2), "Missing lowercase software key for \(letter)")
      key.tap()
    }
    XCTAssertTrue(keyboard.exists, "The software keyboard must remain presented after typing")
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

  private func recordDiagnosticDrag(_ surface: DragSurface, app: XCUIApplication) throws -> GestureTrace {
    let priorSequence = (try? readGestureTrace(app).sequence) ?? 0
    app.buttons["messages.fixture.gesturesMenu"].tap()
    let armID = surface == .center ? "messages.fixture.armCenter" : "messages.fixture.armGutter"
    let arm = app.buttons[armID].firstMatch
    XCTAssertTrue(arm.waitForExistence(timeout: 3))
    arm.tap()
    let armed = try waitForGestureTrace(app) {
      $0.sequence == priorSequence + 1 && $0.status == "recording"
    }
    XCTAssertEqual(armed.kind, surface.rawValue)
    let frame = try XCTUnwrap(armed.collectionFrame)
    let footer = try XCTUnwrap(armed.footerFrame)
    let start = try XCTUnwrap(armed.start)
    let end = try XCTUnwrap(armed.end)
    let sample = try readSample(app)
    let collection = app.collectionViews["messages.fixture.transcript"].firstMatch
    XCTAssertTrue(collection.exists)
    assertRect(frame, equals: sample.collectionFrame, epsilon: sample.epsilon)
    assertRect(frame, equals: .init(collection.frame), epsilon: sample.epsilon)
    XCTAssertGreaterThan(frame.width, 0)
    XCTAssertGreaterThan(frame.height, 0)
    XCTAssertEqual(start.x, end.x, accuracy: sample.epsilon)
    XCTAssertGreaterThan(end.y, start.y)
    XCTAssertLessThan(end.y, footer.y)
    let upper = collection.coordinate(withNormalizedOffset: CGVector(
      dx: CGFloat((start.x - frame.x) / frame.width), dy: CGFloat((start.y - frame.y) / frame.height)))
    let lower = collection.coordinate(withNormalizedOffset: CGVector(
      dx: CGFloat((end.x - frame.x) / frame.width), dy: CGFloat((end.y - frame.y) / frame.height)))
    upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.2)
    let completed = try waitForGestureTrace(app) {
      $0.sequence == armed.sequence && ($0.status == "captured" || $0.status == "timedOut")
    }
    let timeline = try XCTUnwrap(completed.timeline)
    let recognizers = try XCTUnwrap(completed.recognizers)
    let views = try XCTUnwrap(completed.viewPath)
    XCTAssertEqual(completed.timelineLimit, 64)
    XCTAssertEqual(completed.viewLimit, 12)
    XCTAssertEqual(completed.recognizerLimit, 16)
    XCTAssertEqual(completed.byteLimit, 65_536)
    XCTAssertFalse(timeline.isEmpty)
    XCTAssertLessThanOrEqual(timeline.count, 64)
    XCTAssertLessThanOrEqual(views.count, 12)
    XCTAssertLessThanOrEqual(recognizers.count, 16)
    XCTAssertEqual(recognizers.filter { $0.isCollectionPan }.count, 1)
    XCTAssertTrue(timeline.allSatisfy { $0.recognizers.count <= 16 })
    let dropped = try XCTUnwrap(completed.droppedRecordCount)
    XCTAssertGreaterThanOrEqual(dropped, 0)
    XCTAssertEqual(try XCTUnwrap(completed.recordedFrameCount), timeline.count + dropped)
    XCTAssertLessThanOrEqual(try XCTUnwrap(rawGestureTrace(app)).utf8.count, 65_536)
    if completed.status == "captured" {
      XCTAssertEqual(completed.inputObserved, true)
      XCTAssertNotNil(completed.firstInputFrame)
      XCTAssertNotNil(completed.firstReleasedFrame)
    }
    // timedOut is retained as indeterminate input/recognition evidence; the
    // existing center scroll and anchor predicates still determine behavior.
    return completed
  }

  private func assertDiagnosticIdentity(_ trace: GestureTrace, before: Sample, after: Sample) {
    XCTAssertEqual(after.fixtureInstanceID, before.fixtureInstanceID)
    XCTAssertEqual(after.collectionIdentity, before.collectionIdentity)
    XCTAssertEqual(after.editorIdentity, before.editorIdentity)
    XCTAssertNotNil(before.editorIdentity)
    XCTAssertEqual(trace.fixtureInstanceID, before.fixtureInstanceID)
    XCTAssertEqual(trace.collectionIdentity, before.collectionIdentity)
    XCTAssertEqual(trace.finalCollectionIdentity, after.collectionIdentity)
    XCTAssertEqual(trace.editorIdentity, before.editorIdentity)
    XCTAssertEqual(trace.finalEditorIdentity, after.editorIdentity)
    XCTAssertEqual(trace.baselineSample?.fixtureInstanceID, before.fixtureInstanceID)
    XCTAssertEqual(trace.baselineSample?.collectionIdentity, before.collectionIdentity)
    XCTAssertEqual(trace.baselineSample?.editorIdentity, before.editorIdentity)
    XCTAssertEqual(trace.finalSample?.collectionIdentity, after.collectionIdentity)
    XCTAssertEqual(trace.finalSample?.editorIdentity, after.editorIdentity)
    XCTAssertEqual(after.messageCount, before.messageCount)
    XCTAssertEqual(after.localRevision, 0)
    XCTAssertEqual(after.editorTextCount, 0)
    XCTAssertFalse(after.editorIsFirstResponder)
  }

  private func assertUniformFreshLaunches(_ first: Sample, _ second: Sample) {
    XCTAssertNotEqual(first.fixtureInstanceID, second.fixtureInstanceID, "Each control must use a fresh fixture instance")
    XCTAssertEqual(first.messageCount, 32)
    XCTAssertEqual(first.messageCount, second.messageCount)
    XCTAssertEqual(first.localRevision, 0)
    XCTAssertEqual(second.localRevision, 0)
    XCTAssertEqual(first.backdrop, "cyan")
    XCTAssertEqual(second.backdrop, "cyan")
    XCTAssertEqual(first.editorTextCount, 0)
    XCTAssertEqual(second.editorTextCount, 0)
    XCTAssertFalse(first.editorIsFirstResponder)
    XCTAssertFalse(second.editorIsFirstResponder)
    XCTAssertEqual(first.scale, second.scale)
    XCTAssertEqual(first.offsetY, first.legalBottom, accuracy: first.epsilon)
    XCTAssertEqual(second.offsetY, second.legalBottom, accuracy: second.epsilon)
    XCTAssertEqual(first.contentHeight, second.contentHeight, accuracy: second.epsilon)
    XCTAssertEqual(first.legalTop, second.legalTop, accuracy: second.epsilon)
    XCTAssertEqual(first.legalBottom, second.legalBottom, accuracy: second.epsilon)
    XCTAssertEqual(first.insetBottom, second.insetBottom, accuracy: second.epsilon)
    assertRect(first.collectionFrame, equals: second.collectionFrame, epsilon: second.epsilon)
    assertRect(first.footerFrame, equals: second.footerFrame, epsilon: second.epsilon)
    assertRect(first.editorFrame, equals: second.editorFrame, epsilon: second.epsilon)
  }

  private func assertMatchingDragPlans(_ gutter: GestureTrace, _ center: GestureTrace, epsilon: Double) {
    guard let gutterStart = gutter.start, let gutterEnd = gutter.end,
          let centerStart = center.start, let centerEnd = center.end else {
      XCTFail("Both native drags must retain actual start/end points")
      return
    }
    XCTAssertEqual(gutterStart.y, centerStart.y, accuracy: epsilon)
    XCTAssertEqual(gutterEnd.y, centerEnd.y, accuracy: epsilon)
    XCTAssertGreaterThan(gutterStart.x, centerStart.x)
  }

  private func assertRect(_ first: Rect, equals second: Rect, epsilon: Double) {
    XCTAssertEqual(first.x, second.x, accuracy: epsilon)
    XCTAssertEqual(first.y, second.y, accuracy: epsilon)
    XCTAssertEqual(first.width, second.width, accuracy: epsilon)
    XCTAssertEqual(first.height, second.height, accuracy: epsilon)
  }

  private func rawGestureTrace(_ app: XCUIApplication) -> String? {
    let probe = app.descendants(matching: .any)["messages.fixture.gestures"].firstMatch
    guard probe.exists else { return nil }
    return probe.value as? String
  }

  private func readGestureTrace(_ app: XCUIApplication) throws -> GestureTrace {
    guard let raw = rawGestureTrace(app) else { throw FixtureError.sampleMissing }
    return try JSONDecoder().decode(GestureTrace.self, from: Data(raw.utf8))
  }

  private func waitForGestureTrace(_ app: XCUIApplication, _ predicate: (GestureTrace) -> Bool) throws -> GestureTrace {
    let deadline = Date().addingTimeInterval(10)
    repeat {
      if let trace = try? readGestureTrace(app), predicate(trace) { return trace }
      Thread.sleep(forTimeInterval: 0.08)
    } while Date() < deadline
    capture("Failed passive native gesture predicate", app: app, includeGestureTrace: true)
    XCTFail("Timed out waiting for bounded passive native gesture evidence")
    throw FixtureError.sampleTimedOut
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

  private func productionEditor(_ app: XCUIApplication) -> XCUIElement {
    // The retained native failure snapshot gives this inherited container ID
    // to both the editor and placeholder. TextView type plus label is essential.
    let editors = app.textViews.matching(NSPredicate(
      format: "identifier == %@ AND label == %@", "chat.composer.viewporttest", "Local fixture text"
    ))
    let editor = editors.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5), "The actual production TextView must exist")
    XCTAssertEqual(editors.count, 1, "Exactly one production TextView must match the observed ID and label")
    XCTAssertTrue(editor.isHittable)
    return editor
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

  private func capture(_ name: String, app: XCUIApplication, includeGestureTrace: Bool = false) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let geometry = XCTAttachment(string: rawSample(app) ?? "No native geometry sample")
    geometry.name = name + " — UIKit geometry and held-drag witnesses"
    geometry.lifetime = .keepAlways
    add(geometry)
    if includeGestureTrace {
      let trace = XCTAttachment(string: rawGestureTrace(app) ?? "No passive native gesture timeline")
      trace.name = name + " — bounded passive recognizer timeline"
      trace.lifetime = .keepAlways
      add(trace)
    }
  }

  private enum FixtureError: Error { case edgeNotReached, sampleTimedOut, sampleMissing }

  private struct Rect: Decodable {
    let x: Double, y: Double, width: Double, height: Double
    init(_ rect: CGRect) {
      x = Double(rect.minX); y = Double(rect.minY)
      width = Double(rect.width); height = Double(rect.height)
    }
    var maxY: Double { y + height }
    var maxX: Double { x + width }
    var midY: Double { y + height / 2 }
  }
  private struct Point: Decodable { let x: Double, y: Double }
  private struct Insets: Decodable { let top: Double, left: Double, bottom: Double, right: Double }
  private struct Size: Decodable { let width: Double, height: Double }
  private struct GestureRecognizer: Decodable { let identity: String; let isCollectionPan: Bool }
  private struct GestureView: Decodable { let identity: String }
  private struct GestureState: Decodable { let identity: String; let state: String }
  private struct GestureFrame: Decodable { let timestamp: Double; let recognizers: [GestureState] }
  private struct GestureTrace: Decodable {
    let sequence: Int, status: String
    let kind: String?
    let timelineLimit: Int?, viewLimit: Int?, recognizerLimit: Int?, byteLimit: Int?
    let fixtureInstanceID: String?, collectionIdentity: String?, editorIdentity: String?
    let finalCollectionIdentity: String?, finalEditorIdentity: String?
    let collectionFrame: Rect?, footerFrame: Rect?
    let baselineSample: Sample?, finalSample: Sample?
    let start: Point?, end: Point?
    let viewPath: [GestureView]?, recognizers: [GestureRecognizer]?, timeline: [GestureFrame]?
    let recordedFrameCount: Int?, droppedRecordCount: Int?
    let firstInputFrame: GestureFrame?, firstReleasedFrame: GestureFrame?
    let inputObserved: Bool?
  }
  private struct Witness: Decodable {
    let offsetY: Double, legalTop: Double, legalBottom: Double, timestamp: Double
    let isDragging: Bool
  }
  private struct Sample: Decodable {
    let ready: Bool
    let fixtureInstanceID: String
    let sampleCount: Int, resetSequence: Int, messageCount: Int, localRevision: Int, sendCallbackCount: Int
    let backdrop: String
    let scale: Double
    let collectionIdentity: String, editorIdentity: String?
    let collectionFrame: Rect, footerFrame: Rect, editorFrame: Rect
    let caretFrame: Rect?
    let editorFontLineHeight: Double?
    let editorTextContainerInset: Insets?
    let editorContentInset: Insets?
    let editorContentSize: Size?
    let editorContentOffset: Point?
    let editorTextBounds: Rect?
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
