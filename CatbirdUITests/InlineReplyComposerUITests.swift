import XCTest

/// Staged native journeys; these must run against the combined inline composer.
@MainActor
final class InlineReplyComposerUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

  func testLongInlineSourceKeepsEditorAcrossScrollAndRotation() throws {
    let app = launch()
    let editor = try readyEditor(app)
    let initial = try probe(app)
    XCTAssertNotEqual(initial["claim"] as? String, "none")
    XCTAssertEqual(initial["parentURI"] as? String, sourceURI)
    XCTAssertEqual(initial["sourceStartVisible"] as? Bool, false,
                   "The long reply must initially show its editor, rather than the source top")
    try capture(app, "inline-reply-01-initial-editor-keyboard")
    editor.typeText("A typed reply survives reading its original source.")
    let before = try waitProbe(app) { ($0["text"] as? String) == "A typed reply survives reading its original source." }
    assertToolbar(app)
    try capture(app, "inline-reply-02-typed-reply-toolbar")

    let scroll = app.scrollViews["reply-composer-scroll"]
    XCTAssertTrue(scroll.exists)
    try scrollUntil(app, in: scroll, down: true, key: "sourceStartVisible")
    try capture(app, "inline-reply-03-full-source-start")
    try scrollUntil(app, in: scroll, down: false, key: "sourceEndVisible")
    try capture(app, "inline-reply-04-full-source-end")
    try returnToEditor(app, scroll: scroll)
    try assertSameEditor(app, before: before)
    try capture(app, "inline-reply-05-source-return-editor-selection")

    XCUIDevice.shared.orientation = .landscapeLeft
    try waitOrientation(app, landscape: true)
    try returnToEditor(app, scroll: scroll)
    try assertSameEditor(app, before: before)
    XCTAssertTrue(app.buttons["composer-close"].isHittable)
    XCTAssertTrue(app.buttons["composer-drafts"].isHittable)
    try capture(app, "inline-reply-06-landscape-editor-selection")
    XCUIDevice.shared.orientation = .portrait
    try waitOrientation(app, landscape: false)
    try returnToEditor(app, scroll: scroll)
    try assertSameEditor(app, before: before)
    try capture(app, "inline-reply-07-portrait-return-editor-selection")
  }

  func testAccessibilityLargeHasSeparateToolbarAndReachableThreadAdd() throws {
    let app = launch(accessibilityLarge: true)
    let editor = try readyEditor(app)
    let metrics = try probe(app)
    XCTAssertEqual(metrics["systemCategory"] as? String, "UICTContentSizeCategoryAccessibilityL",
                   "This journey requires the actual native Accessibility Large category")
    XCTAssertEqual(metrics["fontCategory"] as? String, "accessibilityLarge")
    assertToolbar(app)
    let add = app.buttons["composer-add-thread-post"]
    XCTAssertTrue(add.isHittable)
    XCTAssertGreaterThanOrEqual(add.frame.width, 44)
    XCTAssertGreaterThanOrEqual(add.frame.height, 44)
    XCTAssertLessThanOrEqual(add.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
    editor.typeText("First reply entry at Accessibility Large.")
    try capture(app, "inline-reply-08-accessibility-large-toolbar-thread-add")
    add.tap()
    let threadEditor = try readyEditor(app)
    threadEditor.typeText("Second local thread entry.")
    _ = try waitProbe(app) { ($0["text"] as? String) == "Second local thread entry." }
    try capture(app, "inline-reply-09-accessibility-large-second-thread-entry")
  }

  func testWhitespaceDismissClearsReplyReferenceBeforeNewPost() throws {
    let app = launch()
    let editor = try readyEditor(app)
    let originalClaim = try probe(app)["claim"] as? String
    editor.typeText(" \n   ")
    _ = try waitProbe(app) { ($0["text"] as? String) == " \n   " }
    app.buttons["composer-close"].tap()
    XCTAssertTrue(app.buttons["inline-reply.new-post"].waitForExistence(timeout: 8))
    let dismissed = try waitProbe(app) {
      ($0["claim"] as? String) == "none" && ($0["hasDraft"] as? Bool) == false
    }
    XCTAssertEqual(dismissed["hasRecovery"] as? Bool, false)
    XCTAssertEqual(dismissed["parentURI"] as? String, "none")
    XCTAssertEqual(dismissed["minimized"] as? Bool, false)
    XCTAssertEqual(dismissed["savedCount"] as? Int, 1,
                   "Empty dismissal must not create a saved library row")
    XCTAssertFalse(app.buttons["inline-reply.resume"].exists)
    try capture(app, "inline-reply-10-whitespace-dismiss-no-reference")

    app.buttons["inline-reply.new-post"].tap()
    _ = try readyEditor(app, title: "Post")
    let fresh = try probe(app)
    XCTAssertNotEqual(fresh["claim"] as? String, originalClaim)
    XCTAssertEqual(fresh["text"] as? String, "")
    XCTAssertEqual(fresh["parentURI"] as? String, "none")
    XCTAssertFalse(app.descendants(matching: .any)["reply-inline-source"].firstMatch.exists)
    try capture(app, "inline-reply-11-fresh-post-no-stale-original")
  }

  func testMeaningfulReplyAutosavesMinimizesAndRestores() throws {
    let app = launch()
    let editor = try readyEditor(app)
    let text = "Meaningful local reply survives autosave and minimize."
    let claim = try probe(app)["claim"] as? String
    editor.typeText(text)
    // Exercise the production 30-second autosave task, without shortening it.
    let saved = try waitProbe(app, timeout: 42) {
      ($0["draftText"] as? String) == text && ($0["persistedText"] as? String) == text
    }
    XCTAssertEqual(saved["persistedParentURI"] as? String, sourceURI)
    XCTAssertEqual(saved["claim"] as? String, claim)
    try capture(app, "inline-reply-12-production-autosave-body-reference")
    dismissNativeSheet(app)
    let minimized = try waitProbe(app) { ($0["minimized"] as? Bool) == true }
    XCTAssertEqual(minimized["claim"] as? String, claim)
    XCTAssertEqual(minimized["persistedText"] as? String, text)
    XCTAssertEqual(minimized["parentURI"] as? String, sourceURI)
    try capture(app, "inline-reply-13-native-minimize-keeps-body-reference")

    let resume = app.buttons["inline-reply.resume"]
    XCTAssertTrue(resume.isHittable)
    resume.tap()
    _ = try readyEditor(app)
    let restored = try waitProbe(app) {
      ($0["text"] as? String) == text && ($0["sourceReads"] as? Int ?? 0) > 0
        && !app.descendants(matching: .any)["reply-source-loading"].firstMatch.exists
    }
    XCTAssertEqual(restored["claim"] as? String, claim)
    XCTAssertEqual(restored["parentURI"] as? String, sourceURI)
    XCTAssertEqual(restored["minimized"] as? Bool, false)
    XCTAssertTrue(app.descendants(matching: .any)["reply-inline-source"].firstMatch.exists)
    try capture(app, "inline-reply-14-restored-local-source-and-typed-reply")
  }

  private let sourceURI = "at://did:plc:inlinereplyfixtureauthor/app.bsky.feed.post/inline-source"

  private func launch(accessibilityLarge: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--inline-reply-ui-fixture", "--support-tip-storekit-test",
                           "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                           "-defaultComposerLanguage", "en",
                           "-UIPreferredContentSizeCategoryName",
                           accessibilityLarge ? "UICTContentSizeCategoryAccessibilityL" : "UICTContentSizeCategoryL"]
    app.launch()
    let open = app.buttons["inline-reply.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 12), app.debugDescription)
    open.tap()
    return app
  }

  private func readyEditor(_ app: XCUIApplication, title: String = "Reply") throws -> XCUIElement {
    XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), app.debugDescription)
    let editor = app.textViews["inline-reply.editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
    _ = try waitProbe(app) { ($0["focused"] as? Bool) == true }
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let quickPath = app.otherElements["UIContinuousPathIntroductionView"]
    if quickPath.exists {
      let proceed = quickPath.buttons["Continue"]
      XCTAssertEqual(quickPath.buttons.matching(identifier: "Continue").count, 1)
      proceed.tap()
    }
    XCTAssertTrue(app.keyboards.keys.matching(NSPredicate(format: "label ==[c] %@", "q"))
      .firstMatch.waitForExistence(timeout: 5),
                  "Typing requires actual alphabetic keys after keyboard onboarding")
    XCTAssertTrue(editor.isHittable, "Initial source positioning must leave the native editor reachable")
    return editor
  }

  private func probe(_ app: XCUIApplication) throws -> [String: Any] {
    let element = app.descendants(matching: .any)["inline-reply.probe"].firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 5))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(element.label.utf8)) as? [String: Any])
  }

  private func waitProbe(_ app: XCUIApplication, timeout: TimeInterval = 8,
                         predicate: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
    let element = app.descendants(matching: .any)["inline-reply.probe"].firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 5))
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let data = try? JSONSerialization.jsonObject(with: Data(element.label.utf8)) as? [String: Any] else { return false }
      return predicate(data)
    }, object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, element.label)
    return try probe(app)
  }

  private func assertSameEditor(_ app: XCUIApplication, before: [String: Any]) throws {
    let after = try probe(app)
    for key in ["identity", "text", "claim"] {
      XCTAssertEqual(after[key] as? String, before[key] as? String, key)
    }
    for key in ["selectionStart", "selectionLength"] {
      XCTAssertEqual(after[key] as? Int, before[key] as? Int, key)
    }
  }

  private func assertToolbar(_ app: XCUIApplication) {
    let close = app.buttons["composer-close"]
    let drafts = app.buttons["composer-drafts"]
    XCTAssertTrue(close.isHittable)
    XCTAssertTrue(drafts.isHittable)
    XCTAssertFalse(close.frame.intersects(drafts.frame))
    XCTAssertGreaterThanOrEqual(abs(close.frame.midX - drafts.frame.midX), 44)
  }

  private func scrollUntil(_ app: XCUIApplication, in scroll: XCUIElement,
                           down: Bool, key: String) throws {
    for _ in 0..<36 {
      let current = try probe(app)
      if current[key] as? Bool == true, rectsVisible(app, probe: current, key: key == "sourceStartVisible" ? "sourceStartGlyphFrames" : "sourceEndGlyphFrames") { return }
      dragSource(app, scroll: scroll, down: down)
    }
    XCTFail("The inline source marker did not enter the actual clipped viewport: \(key)")
  }

  private func dragSource(_ app: XCUIApplication, scroll: XCUIElement, down: Bool) {
    var viewport = scroll.frame.intersection(app.windows.firstMatch.frame)
    let barBottom = app.navigationBars["Reply"].frame.maxY
    let keyboardTop = app.keyboards.firstMatch.frame.minY
    // The keyboard strip ends at the keys; app scroll views above it are not accessories.
    let accessories = app.scrollViews.allElementsBoundByIndex.filter {
      $0.identifier != "reply-composer-scroll" && abs($0.frame.maxY - keyboardTop) <= 1
        && $0.frame.minY >= barBottom && $0.frame.width > viewport.width / 2
    }
    let lower = accessories.map { $0.frame.minY }.min() ?? keyboardTop
    viewport = viewport.intersection(CGRect(x: viewport.minX, y: barBottom,
      width: viewport.width, height: max(0, lower - barBottom)))
    XCTAssertGreaterThan(viewport.height, 0)
    // Contact the measured outer-scroll gutter, not the editor's own pan recognizer.
    let editorFrame = app.textViews["inline-reply.editor"].firstMatch.frame
    XCTAssertGreaterThan(editorFrame.width, 0)
    let gutterStart = max(viewport.minX, editorFrame.maxX)
    XCTAssertGreaterThan(viewport.maxX - gutterStart, 0)
    let contactX = (gutterStart + viewport.maxX) / 2
    // Step within the unobscured band (above the footer), a third of it at a
    // time, and hold before release so no fling carries content past a marker
    // whose visible window is narrower than one half-viewport drag.
    let band = unobscuredReadingRegion(app) ?? viewport
    let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
    let startY = band.minY + band.height * (down ? 0.33 : 0.67)
    let endY = band.minY + band.height * (down ? 0.67 : 0.33)
    origin.withOffset(CGVector(dx: contactX, dy: startY))
      .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: contactX, dy: endY)),
             withVelocity: .slow, thenHoldForDuration: 0.3)
  }

  // Exact production AX controls independently bound the region above the sibling footer.
  // A zero adjustedContentInset cannot admit text behind these controls.
  private func unobscuredReadingRegion(_ app: XCUIApplication) -> CGRect? {
    let window = app.windows.firstMatch.frame
    let bar = app.navigationBars["Reply"]
    let keyboard = app.keyboards.firstMatch
    let add = app.buttons["Attachments and post settings"]
    let thread = app.buttons["composer-add-thread-post"]
    guard bar.exists, keyboard.exists, add.exists, thread.exists else { return nil }
    let chips = app.otherElements.matching(NSPredicate(format: "label == %@", "Language English"))
      .allElementsBoundByIndex.map { $0.frame }.filter { !$0.isEmpty && $0.intersects(window) }
    if window.height > window.width && chips.isEmpty { return nil }
    let footerFrames = chips + [add.frame, thread.frame]
    guard footerFrames.allSatisfy({ !$0.isEmpty && $0.intersects(window) }) else { return nil }
    let top = max(window.minY, bar.frame.maxY)
    let bottom = min(keyboard.frame.minY, footerFrames.map { $0.minY }.min()!)
    guard bottom > top else { return nil }
    return CGRect(x: window.minX, y: top, width: window.width, height: bottom - top)
  }

  private func rectsVisible(_ app: XCUIApplication, probe: [String: Any], key: String,
                            includeCaret: Bool = false) -> Bool {
    guard let viewport = unobscuredReadingRegion(app), let encoded = probe[key] as? [String],
          !encoded.isEmpty else { return false }
    var frames = encoded.map { NSCoder.cgRect(for: $0) }
    if includeCaret {
      guard let caret = probe["editorCaretFrame"] as? String, caret != "none" else { return false }
      frames.append(NSCoder.cgRect(for: caret))
    }
    return frames.allSatisfy { !$0.isEmpty && !$0.isNull && !$0.isInfinite && viewport.contains($0) }
  }

  private func returnToEditor(_ app: XCUIApplication, scroll: XCUIElement) throws {
    let editor = app.textViews["inline-reply.editor"].firstMatch
    for _ in 0..<24 {
      let current = try probe(app)
      if editor.isHittable, current["editorTextAndCaretVisible"] as? Bool == true,
         rectsVisible(app, probe: current, key: "editorGlyphFrames", includeCaret: true) { return }
      // Move toward the editor's actual position; after rotation it can sit
      // above the reading region as well as below it.
      var editorAbove = false
      if let region = unobscuredReadingRegion(app), editor.exists, !editor.frame.isEmpty {
        editorAbove = editor.frame.minY < region.minY
      }
      dragSource(app, scroll: scroll, down: editorAbove)
    }
    XCTFail("Could not return to the existing reply editor by native scrolling")
  }

  private func dismissNativeSheet(_ app: XCUIApplication) {
    for _ in 0..<3 {
      if app.buttons["inline-reply.resume"].exists { return }
      let bar = app.navigationBars["Reply"]
      let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
      start.press(forDuration: 0.1, thenDragTo: end)
    }
    XCTAssertTrue(app.buttons["inline-reply.resume"].waitForExistence(timeout: 8),
                  "A native sheet dismissal must minimize the meaningful reply")
  }

  private func waitOrientation(_ app: XCUIApplication, landscape: Bool) throws {
    let window = app.windows.firstMatch
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (window.frame.width > window.frame.height) == landscape
    }, object: window)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
    _ = try waitProbe(app) {
      guard let width = $0["windowWidth"] as? Double, let height = $0["windowHeight"] as? Double else { return false }
      return (width > height) == landscape
    }
  }

  private func capture(_ app: XCUIApplication, _ name: String) throws {
    var previous: [String: Any]?
    var previousFrame: CGRect?
    var stableSamples = 0
    _ = try waitProbe(app, timeout: 8) { current in
      let currentFrame = app.windows.firstMatch.frame
      let keys = ["identity", "text", "claim", "editorFrame", "editorReadingViewport"]
      let same = previousFrame == currentFrame
        && (previous?["interfaceOrientation"] as? Int) == (current["interfaceOrientation"] as? Int)
        && keys.allSatisfy {
        (previous?[$0] as? String) == (current[$0] as? String)
      }
      stableSamples = same ? stableSamples + 1 : 0
      previous = current
      previousFrame = currentFrame
      return stableSamples >= 2
    }
    let before = try probe(app)
    let frame = app.windows.firstMatch.frame
    let orientation = XCUIDevice.shared.orientation
    let appImage = app.screenshot()
    let screenshot = XCTAttachment(screenshot: appImage)
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    // XCUIScreen observes the actual device screen independently of app capture.
    // Preserve both original images; dimension checks alone do not prove readable pixels.
    let screen = XCUIScreen.main.screenshot()
    let deviceImage = XCTAttachment(screenshot: screen)
    deviceImage.name = name + "-device-screen"
    deviceImage.lifetime = .keepAlways
    add(deviceImage)
    let after = try probe(app)
    XCTAssertEqual(app.windows.firstMatch.frame, frame)
    XCTAssertEqual(XCUIDevice.shared.orientation, orientation)
    for key in ["identity", "text", "claim", "editorReadingViewport"] {
      XCTAssertEqual(before[key] as? String, after[key] as? String, "Capture state changed: " + key)
    }
    let width = try XCTUnwrap(after["windowWidth"] as? Double)
    let height = try XCTUnwrap(after["windowHeight"] as? Double)
    XCTAssertEqual(Double(frame.width), width, accuracy: 1)
    XCTAssertEqual(Double(frame.height), height, accuracy: 1)
    let sceneOrientation = try XCTUnwrap(after["interfaceOrientation"] as? Int)
    XCTAssertTrue((1...4).contains(sceneOrientation), "Native scene orientation must be known")
    XCTAssertEqual(before["interfaceOrientation"] as? Int, sceneOrientation)
    XCTAssertEqual(sceneOrientation == 3 || sceneOrientation == 4, width > height)
    let pixels = try XCTUnwrap(screen.image.cgImage)
    let swapsAxes = [.left, .right, .leftMirrored, .rightMirrored].contains(screen.image.imageOrientation)
    let displayWidth = swapsAxes ? pixels.height : pixels.width
    let displayHeight = swapsAxes ? pixels.width : pixels.height
    XCTAssertEqual(displayWidth > displayHeight, width > height,
                   "Actual device-screen raster orientation must match current native geometry")
    XCTAssertEqual(Double(displayWidth) / Double(displayHeight), width / height, accuracy: 0.01)
    let appPixels = try XCTUnwrap(appImage.image.cgImage)
    let metadata: [String: Any] = ["windowFrame": NSCoder.string(for: frame),
      "nativeDeviceOrientation": orientation.rawValue,
      "appPixelWidth": appPixels.width, "appPixelHeight": appPixels.height,
      "appImageOrientation": appImage.image.imageOrientation.rawValue,
      "screenPixelWidth": pixels.width, "screenPixelHeight": pixels.height,
      "screenImageOrientation": screen.image.imageOrientation.rawValue,
      "screenDeclaredDisplayWidth": displayWidth, "screenDeclaredDisplayHeight": displayHeight,
      "probeBefore": before, "probeAfter": after,
      "axUnobscuredReadingRegion": unobscuredReadingRegion(app).map { NSCoder.string(for: $0) } ?? "unavailable",
      "pixelContentRequiresIndependentVisualReview": true]
    let captureState = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
                                     uniformTypeIdentifier: "public.json")
    captureState.name = name + "-capture-geometry"
    captureState.lifetime = .keepAlways
    add(captureState)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "\(name)-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
    let metrics = app.descendants(matching: .any)["inline-reply.probe"].firstMatch.label
    let oracle = XCTAttachment(string: metrics)
    oracle.name = "\(name)-native-probe"
    oracle.lifetime = .keepAlways
    add(oracle)
  }
}
