import XCTest

final class ModerationMutedQuoteRevealUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMutedQuoteLabelAndMediaCanBeShownAndHiddenWithoutMovingOuterText() throws {
    try verifyRepeatedLabelAndMediaReveals()
  }

  func testRepeatedMediaRevealWithReduceMotionKeepsViewportStable() throws {
    try verifyRepeatedLabelAndMediaReveals(arguments: ["--moderation-reduce-motion"])
  }

  private func verifyRepeatedLabelAndMediaReveals(arguments: [String] = []) throws {
    let app = launchFixture(["--moderation-layout-diagnostics", "--moderation-reveal-room-below"] + arguments)
    let feed = app.collectionViews.firstMatch
    XCTAssertTrue(feed.waitForExistence(timeout: 10))
    let outerText = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "A synthetic outer post quotes an account the viewer muted")
    ).firstMatch
    let mutedQuoteShow = app.buttons.matching(identifier: "moderation.mutedQuote.show").firstMatch
    scrollToMutedQuote(show: mutedQuoteShow, in: feed)
    XCTAssertTrue(mutedQuoteShow.waitForExistence(timeout: 10))
    XCTAssertTrue(outerText.exists)
    let outerTextY = waitForStableY(outerText)
    capture("Muted quote before reveal", app)

    mutedQuoteShow.tap()
    let contentToggle = app.buttons.matching(identifier: "moderation.contentGate.toggle").firstMatch
    XCTAssertTrue(contentToggle.waitForExistence(timeout: 5))
    XCTAssertTrue(outerText.exists)
    let revealedY = waitForStableY(outerText)
    capture("Muted quote revealed beneath stable outer post", app)
    XCTAssertEqual(revealedY, outerTextY, accuracy: 1)

    let probe = app.descendants(matching: .any).matching(identifier: "moderation.fixture.geometry").firstMatch
    let cell = app.descendants(matching: .any).matching(identifier: "moderation.fixture.outerCell").firstMatch
    waitForDiagnosticLayout(cell)
    let baseline = try lastGeometry(probe)
    contentToggle.tap()
    waitForDiagnosticLayout(cell)
    try assertViewportStable(probe, since: baseline)
    let mediaShow = app.buttons.matching(identifier: "moderation.mediaGate.show")
      .matching(NSPredicate(format: "label == %@", "Show")).firstMatch
    XCTAssertTrue(mediaShow.waitForExistence(timeout: 5))
    // SwiftUI also propagates the nested identifier to the enclosing quote button.
    // Select the actual control, whose label and bounds identify the intended tap.
    let mediaHide = app.buttons.matching(identifier: "moderation.mediaGate.hide")
      .matching(NSPredicate(format: "label == %@", "Hide")).firstMatch
    for cycle in 0..<2 {
      try tapVisibleControlPreservingViewport(mediaShow, in: feed, cell: cell, probe: probe)
      XCTAssertTrue(mediaHide.waitForExistence(timeout: 5))
      if cycle == 0 { capture("Nested label and media gates revealed", app) }
      try tapVisibleControlPreservingViewport(mediaHide, in: feed, cell: cell, probe: probe)
      XCTAssertTrue(mediaShow.waitForExistence(timeout: 5))
    }

    contentToggle.tap()
    XCTAssertEqual(contentToggle.label, "Show")
    XCTAssertFalse(mediaShow.exists)
    XCTAssertTrue(outerText.exists)
    contentToggle.tap()
    XCTAssertEqual(contentToggle.label, "Hide")
    contentToggle.tap()
    XCTAssertEqual(contentToggle.label, "Show")
  }

  func testMutedQuoteRevealRunsWithReduceMotionEnabled() {
    let app = launchFixture(["--moderation-reduce-motion"])
    let banner = app.staticTexts["moderation.fixture.banner"]
    XCTAssertTrue(banner.waitForExistence(timeout: 10))
    XCTAssertTrue(banner.label.contains("reduce motion ON"))
    let feed = app.collectionViews.firstMatch
    let show = app.buttons.matching(identifier: "moderation.mutedQuote.show").firstMatch
    scrollToMutedQuote(show: show, in: feed)
    XCTAssertTrue(show.waitForExistence(timeout: 5))
    let outerText = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "A synthetic outer post quotes an account the viewer muted")
    ).firstMatch
    let outerTextY = waitForStableY(outerText)
    capture("Reduce Motion muted quote before reveal", app)
    show.tap()
    let contentToggle = app.buttons.matching(identifier: "moderation.contentGate.toggle").firstMatch
    XCTAssertTrue(contentToggle.waitForExistence(timeout: 5))
    let revealedY = waitForStableY(outerText)
    capture("Reduce Motion muted quote revealed", app)
    XCTAssertEqual(revealedY, outerTextY, accuracy: 1)
  }

  func testDiagnosticMutedQuoteRevealAtFeedEnd() throws {
    try captureMutedQuoteRevealDiagnostics(scenario: "Feed end")
  }

  func testDiagnosticMutedQuoteRevealWithRoomBelow() throws {
    try captureMutedQuoteRevealDiagnostics(
      scenario: "Room below", extra: ["--moderation-reveal-room-below"])
  }

  func testUnlabelledMutedQuoteWithLongTextAndMediaAtFeedEnd() throws {
    try captureMutedQuoteRevealDiagnostics(
      scenario: "Unlabelled long quote", extra: ["--moderation-quote-without-labels"])
  }

  func testUnlabelledMutedQuoteWithShortTextWithoutMedia() throws {
    try captureMutedQuoteRevealDiagnostics(
      scenario: "Unlabelled short quote", extra: [
        "--moderation-quote-without-labels", "--moderation-quote-short-text",
        "--moderation-quote-without-media", "--moderation-reveal-room-below",
      ])
  }

  func testUnlabelledMutedQuoteWithReduceMotion() throws {
    try captureMutedQuoteRevealDiagnostics(
      scenario: "Unlabelled Reduce Motion", extra: [
        "--moderation-quote-without-labels", "--moderation-reduce-motion",
        "--moderation-reveal-room-below",
      ])
  }

  func testNestedBodyGateCyclesKeepTheOuterRowStableWithRoomBelow() throws {
    let app = launchFixture([
      "--moderation-layout-diagnostics", "--moderation-reveal-room-below",
      "--moderation-quote-short-text", "--moderation-quote-without-media",
    ])
    let feed = app.collectionViews.firstMatch
    let show = app.buttons.matching(identifier: "moderation.mutedQuote.show").firstMatch
    scrollToMutedQuote(show: show, in: feed)
    show.tap()
    let toggle = app.buttons.matching(identifier: "moderation.contentGate.toggle").firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    let probe = app.descendants(matching: .any).matching(identifier: "moderation.fixture.geometry").firstMatch
    let cell = app.descendants(matching: .any).matching(identifier: "moderation.fixture.outerCell").firstMatch
    waitForDiagnosticLayout(cell)
    let before = try lastGeometry(probe)
    for _ in 0..<3 {
      XCTAssertEqual(toggle.label, "Show")
      toggle.tap()
      XCTAssertEqual(toggle.label, "Hide")
      waitForDiagnosticLayout(cell)
      try assertViewportStable(probe, since: before)
      toggle.tap()
      XCTAssertEqual(toggle.label, "Show")
      waitForDiagnosticLayout(cell)
      try assertViewportStable(probe, since: before)
    }
    waitForDiagnosticLayout(cell)
    let after = try lastGeometry(probe)
    XCTAssertEqual(before["cellToken"] as? Int, after["cellToken"] as? Int)
    XCTAssertEqual(try number(before, "offsetY"), try number(after, "offsetY"), accuracy: 1)
    let beforeFrame = try XCTUnwrap(before["cellWindowFrame"] as? [String: Any])
    let afterFrame = try XCTUnwrap(after["cellWindowFrame"] as? [String: Any])
    XCTAssertEqual(try number(beforeFrame, "y"), try number(afterFrame, "y"), accuracy: 1)
    try captureRevealDiagnosticState("Repeated nested body cycles", app: app, probe: probe, outerCell: cell)
  }

  func testMutedQuoteRemainsRevealableAfterScrollingOutAndBack() {
    let app = launchFixture(["--moderation-reveal-room-below"])
    let feed = app.collectionViews.firstMatch
    let show = app.buttons.matching(identifier: "moderation.mutedQuote.show").firstMatch
    scrollToMutedQuote(show: show, in: feed)
    show.tap()
    let toggle = app.buttons.matching(identifier: "moderation.contentGate.toggle").firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    let banner = app.staticTexts["moderation.fixture.banner"]
    for _ in 0..<5 where !banner.isHittable { feed.swipeDown() }
    XCTAssertTrue(banner.isHittable)
    XCTAssertFalse(toggle.isHittable)
    for _ in 0..<5 where !show.isHittable && !toggle.isHittable { feed.swipeUp() }
    // A discarded hosting root may forget its local reveal. Neither case may
    // bypass the quoted post's independent body warning after recycling.
    if show.isHittable { show.tap() }
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.label, "Show")
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(
      format: "label BEGINSWITH %@", "Synthetic quote text with enough words")).firstMatch.exists)
    toggle.tap()
    XCTAssertEqual(toggle.label, "Hide")
    toggle.tap()
    XCTAssertEqual(toggle.label, "Show")
    capture("Quoted label still gates content after viewport reuse", app)
  }

  func testTopLevelFeedMediaGateShowAndHideStepsInOneFrameTopAnchored() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--moderation-ui-fixture",
      "--moderation-scene=adult-on-b",
      "--moderation-feed-collection",
      "--moderation-layout-diagnostics",
      "--moderation-reveal-lead-in",
      "--moderation-reveal-room-below",
    ]
    app.launch()

    let feed = app.collectionViews.firstMatch
    XCTAssertTrue(feed.waitForExistence(timeout: 10))
    let probe = app.descendants(matching: .any)
      .matching(identifier: "moderation.fixture.geometry").firstMatch
    XCTAssertTrue(probe.waitForExistence(timeout: 10))

    let mediaShow = app.buttons.matching(identifier: "moderation.mediaGate.show")
      .matching(NSPredicate(format: "label == %@", "Show")).firstMatch
    let mediaHide = app.buttons.matching(identifier: "moderation.mediaGate.hide")
      .matching(NSPredicate(format: "label == %@", "Hide")).firstMatch
    scrollToMutedQuote(show: mediaShow, in: feed)

    let cell = app.descendants(matching: .any)
      .matching(identifier: "moderation.fixture.outerCell").firstMatch
    XCTAssertTrue(cell.waitForExistence(timeout: 5))
    waitForDiagnosticLayout(cell)

    // Verify Show expands height in 1 single display step with 0pt top jump and 0 geometry animations.
    capture("Top-level CW media before Show", app)
    let beforeShow = try tapVisibleControlPreservingViewport(mediaShow, in: feed, cell: cell, probe: probe)
    let beforeShowHeight = try number(try XCTUnwrap(beforeShow["cellWindowFrame"] as? [String: Any]), "height")
    XCTAssertTrue(mediaHide.waitForExistence(timeout: 5))
    capture("Top-level CW media after Show", app)

    let afterShow = try lastGeometry(probe)
    let afterShowHeight = try number(try XCTUnwrap(afterShow["cellWindowFrame"] as? [String: Any]), "height")
    XCTAssertGreaterThan(afterShowHeight - beforeShowHeight, 30, "Revealing unreserved media must expand cell height")
    try assertOneFrameStepAndZeroGeometryAnimations(
      probe,
      since: beforeShow,
      startHeight: beforeShowHeight,
      endHeight: afterShowHeight
    )

    // Verify Hide shrinks height in 1 single display step with 0pt top jump and 0 geometry animations.
    let beforeHide = try tapVisibleControlPreservingViewport(mediaHide, in: feed, cell: cell, probe: probe)
    let beforeHideHeight = try number(try XCTUnwrap(beforeHide["cellWindowFrame"] as? [String: Any]), "height")
    XCTAssertTrue(mediaShow.waitForExistence(timeout: 5))
    capture("Top-level CW media after Hide", app)

    let afterHide = try lastGeometry(probe)
    let afterHideHeight = try number(try XCTUnwrap(afterHide["cellWindowFrame"] as? [String: Any]), "height")
    XCTAssertEqual(afterHideHeight, beforeShowHeight, accuracy: 2)
    try assertOneFrameStepAndZeroGeometryAnimations(
      probe,
      since: beforeHide,
      startHeight: beforeHideHeight,
      endHeight: afterHideHeight
    )

    // Scroll with zero-momentum hold-drag so the cell's top header/avatar are partially tucked
    // ~30pt above adjustedTop while both Show and Hide remain comfortably inside viewport —
    // the exact geometry where UIKit's default self-sizing anchor previously jumped contentOffset.
    for _ in 0..<8 {
      let current = try lastGeometry(probe)
      let cellFrame = try XCTUnwrap(current["cellWindowFrame"] as? [String: Any])
      let collectionFrame = try XCTUnwrap(current["collectionWindow"] as? [String: Any])
      let topVisibleBoundary = try number(collectionFrame, "y") + (try number(current, "adjustedTop"))
      let cellTopY = try number(cellFrame, "y")
      let targetCellTopY = topVisibleBoundary - 28
      let delta = cellTopY - targetCellTopY
      if cellTopY < topVisibleBoundary - 8 && cellTopY > topVisibleBoundary - 56 {
        break
      }
      let dragOffset = delta + (delta > 0 ? 14 : -14)
      let clampedDelta = min(max(dragOffset, -240), 240)
      let start = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.6))
      let end = start.withOffset(CGVector(dx: 0, dy: -clampedDelta))
      start.press(forDuration: 0.02, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.25)
      waitForDiagnosticLayout(cell)
    }

    let tuckedBaseline = try lastGeometry(probe)
    let tuckedCollectionFrame = try XCTUnwrap(tuckedBaseline["collectionWindow"] as? [String: Any])
    let topVisibleBoundary = try number(tuckedCollectionFrame, "y") + (try number(tuckedBaseline, "adjustedTop"))
    let tuckedCellFrame = try XCTUnwrap(tuckedBaseline["cellWindowFrame"] as? [String: Any])
    XCTAssertLessThan(
      try number(tuckedCellFrame, "y"),
      topVisibleBoundary,
      "Cell top must be partially tucked above top inset before partial-tuck Show/Hide check"
    )
    capture("Partially tucked CW media before Show", app)

    let tuckedBeforeShow = try tapVisibleControlPreservingViewport(mediaShow, in: feed, cell: cell, probe: probe)
    let tuckedBeforeShowCell = try XCTUnwrap(tuckedBeforeShow["cellWindowFrame"] as? [String: Any])
    XCTAssertLessThan(
      try number(tuckedBeforeShowCell, "y"),
      topVisibleBoundary,
      "Cell top must still be partially tucked above top inset at the moment Show is tapped"
    )
    let tuckedBeforeShowH = try number(tuckedBeforeShowCell, "height")
    XCTAssertTrue(mediaHide.waitForExistence(timeout: 5))
    capture("Partially tucked CW media after Show", app)
    let tuckedAfterShow = try lastGeometry(probe)
    let tuckedAfterShowH = try number(try XCTUnwrap(tuckedAfterShow["cellWindowFrame"] as? [String: Any]), "height")
    XCTAssertGreaterThan(tuckedAfterShowH - tuckedBeforeShowH, 30)
    try assertOneFrameStepAndZeroGeometryAnimations(
      probe,
      since: tuckedBeforeShow,
      startHeight: tuckedBeforeShowH,
      endHeight: tuckedAfterShowH
    )

    let tuckedBeforeHide = try tapVisibleControlPreservingViewport(mediaHide, in: feed, cell: cell, probe: probe)
    let tuckedBeforeHideCell = try XCTUnwrap(tuckedBeforeHide["cellWindowFrame"] as? [String: Any])
    XCTAssertLessThan(
      try number(tuckedBeforeHideCell, "y"),
      topVisibleBoundary,
      "Cell top must remain partially tucked above top inset at the moment Hide is tapped"
    )
    let tuckedBeforeHideH = try number(tuckedBeforeHideCell, "height")
    XCTAssertTrue(mediaShow.waitForExistence(timeout: 5))
    capture("Partially tucked CW media after Hide", app)
    let tuckedAfterHide = try lastGeometry(probe)
    let tuckedAfterHideH = try number(try XCTUnwrap(tuckedAfterHide["cellWindowFrame"] as? [String: Any]), "height")
    XCTAssertEqual(tuckedAfterHideH, tuckedBeforeShowH, accuracy: 2)
    try assertOneFrameStepAndZeroGeometryAnimations(
      probe,
      since: tuckedBeforeHide,
      startHeight: tuckedBeforeHideH,
      endHeight: tuckedAfterHideH
    )
  }

  private func assertOneFrameStepAndZeroGeometryAnimations(
    _ probe: XCUIElement,
    since baseline: [String: Any],
    startHeight: Double,
    endHeight: Double
  ) throws {
    let value = try XCTUnwrap(probe.value as? String)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    let events = try XCTUnwrap(json["events"] as? [[String: Any]])
    let sequence = try number(baseline, "sequence")
    let baselineWindowFrame = try XCTUnwrap(baseline["cellWindowFrame"] as? [String: Any])
    let baselineOriginY = try number(baselineWindowFrame, "y")

    var distinctHeights: [Double] = []
    for event in events where ((event["sequence"] as? NSNumber)?.doubleValue ?? -1) > sequence {
      let animCount = (event["geometryAnimationCount"] as? NSNumber)?.intValue ?? 0
      XCTAssertEqual(animCount, 0, "Zero non-opacity CAAnimations allowed during CW resize")
      if let presFrame = event["cellPresentationWindowFrame"] as? [String: Any] {
        XCTAssertEqual(try number(presFrame, "y"), baselineOriginY, accuracy: 1.5,
          "Presentation layer top Y must remain anchored at 0pt jump")
      }
      if let winFrame = event["cellWindowFrame"] as? [String: Any] {
        let h = try number(winFrame, "height")
        if distinctHeights.last.map({ abs($0 - h) > 1.5 }) ?? true {
          distinctHeights.append(h)
        }
        let matchesStartOrEnd = abs(h - startHeight) <= 2.0 || abs(h - endHeight) <= 2.0
        XCTAssertTrue(matchesStartOrEnd,
          "Cell height must step in 1 single frame without intermediate heights; saw \(h) between \(startHeight) and \(endHeight)")
      }
    }
  }

  private func captureMutedQuoteRevealDiagnostics(scenario: String, extra: [String] = []) throws {
    let app = launchFixture(["--moderation-layout-diagnostics"] + extra)
    let feed = app.collectionViews.firstMatch
    XCTAssertTrue(feed.waitForExistence(timeout: 10))
    let probe = app.descendants(matching: .any)
      .matching(identifier: "moderation.fixture.geometry").firstMatch
    XCTAssertTrue(probe.waitForExistence(timeout: 10))
    let show = app.buttons.matching(identifier: "moderation.mutedQuote.show").firstMatch
    scrollToMutedQuote(show: show, in: feed)
    let outerCell = app.descendants(matching: .any)
      .matching(identifier: "moderation.fixture.outerCell").firstMatch
    XCTAssertTrue(outerCell.waitForExistence(timeout: 5))
    waitForDiagnosticLayout(outerCell)
    try captureRevealDiagnosticState("\(scenario) before Show", app: app, probe: probe, outerCell: outerCell)
    let before = try lastGeometry(probe)
    let outerText = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "A synthetic outer post quotes an account the viewer muted")
    ).firstMatch
    let beforeTextY = outerText.frame.minY

    show.tap()
    if extra.contains("--moderation-quote-without-labels") {
      let quote = app.staticTexts.matching(NSPredicate(
        format: "label BEGINSWITH %@", extra.contains("--moderation-quote-short-text")
          ? "Short synthetic quote." : "Synthetic quote text with enough words"
      )).firstMatch
      XCTAssertTrue(quote.waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons.matching(identifier: "moderation.contentGate.toggle").firstMatch.exists)
    } else {
      let contentToggle = app.buttons.matching(identifier: "moderation.contentGate.toggle").firstMatch
      XCTAssertTrue(contentToggle.waitForExistence(timeout: 5))
    }
    XCTAssertTrue(outerCell.exists)
    waitForDiagnosticLayout(outerCell)
    try captureRevealDiagnosticState("\(scenario) after Show", app: app, probe: probe, outerCell: outerCell)
    let after = try lastGeometry(probe)
    try assertViewportStable(probe, since: before)
    XCTAssertEqual(before["cellToken"] as? Int, after["cellToken"] as? Int, "Show must keep the outer cell")
    XCTAssertEqual(try number(before, "offsetY"), try number(after, "offsetY"), accuracy: 1)
    XCTAssertEqual(beforeTextY, outerText.frame.minY, accuracy: 1)
    let beforeFrame = try XCTUnwrap(before["cellContentFrame"] as? [String: Any])
    let afterFrame = try XCTUnwrap(after["cellContentFrame"] as? [String: Any])
    XCTAssertEqual(try number(beforeFrame, "y"), try number(afterFrame, "y"), accuracy: 1)
    XCTAssertGreaterThanOrEqual(try number(afterFrame, "height"), try number(beforeFrame, "height") - 1)
  }

  /// Deliberate navigation must settle before the reveal measurement starts.
  /// A normal XCUIElement.tap can silently scroll an off-screen media control.
  @discardableResult
  private func tapVisibleControlPreservingViewport(
    _ control: XCUIElement, in feed: XCUIElement, cell: XCUIElement, probe: XCUIElement
  ) throws -> [String: Any] {
    let viewport = feed.frame.insetBy(dx: 0, dy: 24)
    for _ in 0..<4 where !viewport.contains(control.frame) {
      let distance = min(max(control.frame.midY - viewport.midY, -viewport.height * 0.4), viewport.height * 0.4)
      let start = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      let end = start.withOffset(CGVector(dx: 0, dy: -distance))
      start.press(forDuration: 0.05, thenDragTo: end)
      waitForDiagnosticLayout(cell)
    }
    XCTAssertTrue(viewport.contains(control.frame), "Position the entire control before measuring its tap")
    waitForDiagnosticLayout(cell)
    let baseline = try lastGeometry(probe)
    if let value = probe.value as? String {
      attachDiagnosticJSON(Data(value.utf8), name: "Media gate before tap geometry.json")
    }
    control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    waitForDiagnosticLayout(cell)
    if let value = probe.value as? String {
      attachDiagnosticJSON(Data(value.utf8), name: "Media gate after tap geometry.json")
    }
    try assertViewportStable(probe, since: baseline)
    return baseline
  }

  /// Inspect every changed display sample after the tap, including movement
  /// that returns to the original position before the final assertion.
  private func assertViewportStable(_ probe: XCUIElement, since baseline: [String: Any]) throws {
    let value = try XCTUnwrap(probe.value as? String)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    let events = try XCTUnwrap(json["events"] as? [[String: Any]])
    let sequence = try number(baseline, "sequence")
    let frame = try XCTUnwrap(baseline["cellWindowFrame"] as? [String: Any])
    let originY = try number(frame, "y")
    let offsetY = try number(baseline, "offsetY")
    for event in events where ((event["sequence"] as? NSNumber)?.doubleValue ?? -1) > sequence {
      XCTAssertEqual(event["cellToken"] as? Int, baseline["cellToken"] as? Int,
        "Reveal must retain the outer cell throughout the transition")
      XCTAssertEqual(try number(event, "offsetY"), offsetY, accuracy: 1,
        "Reveal must not move the viewport during the transition")
      let current = try XCTUnwrap(event["cellWindowFrame"] as? [String: Any])
      XCTAssertEqual(try number(current, "y"), originY, accuracy: 1,
        "Reveal must not move the outer row during the transition")
    }
  }

  private func lastGeometry(_ probe: XCUIElement) throws -> [String: Any] {
    let value = try XCTUnwrap(probe.value as? String)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    let events = try XCTUnwrap(json["events"] as? [[String: Any]])
    return try XCTUnwrap(events.last(where: { $0["cellToken"] != nil }))
  }

  private func number(_ object: [String: Any], _ key: String) throws -> Double {
    try XCTUnwrap(object[key] as? NSNumber).doubleValue
  }

  private func captureRevealDiagnosticState(
    _ name: String, app: XCUIApplication, probe: XCUIElement, outerCell: XCUIElement
  ) throws {
    capture(name, app)
    let matches = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "A synthetic outer post quotes an account the viewer muted")
    ).allElementsBoundByIndex
    let accessibility: [String: Any] = [
      "phase": name,
      "outerCell": diagnosticAccessibilityRecord(outerCell),
      "outerTextMatches": matches.map { diagnosticAccessibilityRecord($0) },
    ]
    let accessibilityData = try JSONSerialization.data(
      withJSONObject: accessibility, options: [.prettyPrinted, .sortedKeys])
    attachDiagnosticJSON(accessibilityData, name: "\(name) accessibility.json")

    let probeValue = try XCTUnwrap(probe.value as? String, "The geometry probe must expose JSON")
    let probeData = Data(probeValue.utf8)
    attachDiagnosticJSON(probeData, name: "\(name) geometry.json")
    let geometry = try XCTUnwrap(
      JSONSerialization.jsonObject(with: probeData) as? [String: Any],
      "The geometry probe must contain a JSON object")
    _ = try XCTUnwrap(geometry["events"] as? [[String: Any]], "The geometry probe must contain events")
  }

  private func diagnosticAccessibilityRecord(_ element: XCUIElement) -> [String: Any] {
    let frame = element.frame
    return [
      "type": String(describing: element.elementType),
      "typeRawValue": element.elementType.rawValue,
      "identifier": element.identifier,
      "label": element.label,
      "frame": [
        "x": Double(frame.origin.x), "y": Double(frame.origin.y),
        "width": Double(frame.size.width), "height": Double(frame.size.height),
      ],
    ]
  }

  private func attachDiagnosticJSON(_ data: Data, name: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Allow fitting and delayed probe samples to settle without imposing a motion oracle.
  private func waitForDiagnosticLayout(_ element: XCUIElement) {
    let start = Date()
    var previousFrame: CGRect?
    var stableReadings = 0
    while Date().timeIntervalSince(start) < 3 {
      guard element.exists else { return }
      let frame = element.frame
      if let previousFrame, frame == previousFrame {
        stableReadings += 1
      } else {
        stableReadings = 0
      }
      if Date().timeIntervalSince(start) >= 1.5, stableReadings >= 3 { return }
      previousFrame = frame
      RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
  }

  private func launchFixture(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--moderation-ui-fixture", "--moderation-scene=muted-quote"] + extra
    app.launch()
    return app
  }

  private func capture(_ name: String, _ app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func scrollToMutedQuote(show: XCUIElement, in feed: XCUIElement) {
    var attempts = 0
    while !show.isHittable && attempts < 5 {
      feed.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(show.isHittable, "The synthetic muted quote should be scrolled into the collection viewport")
  }

  private func waitForStableY(_ element: XCUIElement, timeout: TimeInterval = 3) -> CGFloat {
    let deadline = Date().addingTimeInterval(timeout)
    var previousY: CGFloat?
    var stableReadings = 0

    while Date() < deadline {
      let currentY = element.frame.minY
      if let previousY, abs(currentY - previousY) < 0.5 {
        stableReadings += 1
        if stableReadings >= 3 { return currentY }
      } else {
        stableReadings = 0
      }
      previousY = currentY
      RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    XCTFail("The outer post did not settle at a stable viewport position")
    return element.frame.minY
  }
}
