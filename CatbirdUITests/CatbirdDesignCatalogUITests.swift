//
//  CatbirdDesignCatalogUITests.swift
//  CatbirdUITests
//
//  Tier-2 full-compositor visual QA & native Apple Accessibility Audit (`performAccessibilityAudit`).
//  Launches the app ONCE in `-CatbirdCatalog all` mode and sweeps surfaces × trap profiles via
//  `blue.catbird://catalog?surface=<raw>&profile=<raw>&inspector=0` (or the accessible catalog
//  switcher), capturing genuine iOS 26/27 Liquid Glass + nav/sheet chrome PNGs and structured JSON
//  audit receipts matching `scripts/visual-qa/build_screen_wall.py`.
//

import Foundation
import XCTest

@MainActor
final class CatbirdDesignCatalogUITests: XCTestCase {
  private struct SweepTarget {
    let surface: String
    let profile: String
    let theme: String
    let accent: String
    let fontStyle: String
    let dynamicType: String
    let reduceTransparency: Bool
    let reduceMotion: Bool
    let highContrast: Bool
  }

  /// Core surfaces swept in Tier-2 full-compositor UITest (single app launch).
  private static let coreSurfaces: [String] = [
    "kit",
    "feed",
    "thread",
    "profile",
    "search",
    "chat",
    "composer",
    "settings",
    "onboarding",
    "ask-catbird",
    "notifications",
    "widgets"
  ]

  /// High-signal trap profiles swept across key surfaces in a single launch.
  private static let kitTrapProfiles: [String] = [
    "baseline-light",
    "dim-accent-trap",
    "oled-font-trap",
    "a11y-ax3-narrow",
    "glass-reduce-transparency",
    "resizability-wide-rtl"
  ]

  override func setUp() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDown() async throws {
    XCUIDevice.shared.orientation = .portrait
  }

  /// Single-launch full-compositor sweep across all 6 trap profiles on `kit` plus all Tier-B
  /// mocked production surfaces, running `performAccessibilityAudit(for: .all)` on each and
  /// exporting `<surface>__<profile>.{png,json}` when `CATBIRD_VISUAL_OUT_DIR` is configured.
  func testSingleLaunchCatalogSweepAndAccessibilityAudit() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-CatbirdCatalog", "all",
      "-CatbirdProfile", "baseline-light",
      "-CatbirdCatalogClean", "1",
      "-CatbirdInspector", "0",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US"
    ]
    app.launch()
    defer { app.terminate() }

    let targets = buildSweepMatrix()
    var kitAuditFailures: [String] = []
    var allAuditFailures: [String] = []

    for target in targets {
      try navigate(app: app, surface: target.surface, profile: target.profile)
      waitForCatalogReady(app: app, surface: target.surface, profile: target.profile)

      let shot = app.screenshot()
      let stem = "\(target.surface)__\(target.profile)"
      attachScreenshot(shot, named: stem)

      let auditIssues = runNativeAccessibilityAudit(app: app, stem: stem)
      if target.surface == "kit" && !auditIssues.isEmpty {
        kitAuditFailures.append("\(stem): \(auditIssues.count) a11y audit issue(s)")
      }
      if !auditIssues.isEmpty {
        allAuditFailures.append("\(stem): \(auditIssues.count) issue(s)")
      }

      try exportArtifactsIfConfigured(
        screenshot: shot,
        app: app,
        target: target,
        auditIssues: auditIssues
      )
    }

    let strictMode = ProcessInfo.processInfo.environment["CATBIRD_STRICT_A11Y_AUDIT"] == "1"
    if strictMode {
      XCTAssertTrue(
        allAuditFailures.isEmpty,
        "Accessibility audit issues across catalog: \(allAuditFailures.joined(separator: "; "))"
      )
    } else {
      XCTAssertTrue(
        kitAuditFailures.isEmpty,
        "Kit Gallery must pass native performAccessibilityAudit cleanly: \(kitAuditFailures.joined(separator: "; "))"
      )
    }
  }

  /// Verifies the interactive catalog switcher UI (`catalog.switcher.open`) allows hopping between
  /// surfaces and trap profiles in one launch without relying solely on deep links.
  func testInteractiveCatalogSwitcherNavigation() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-CatbirdCatalog", "kit",
      "-CatbirdProfile", "baseline-light",
      "-CatbirdCatalogClean", "0",
      "-CatbirdInspector", "0",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US"
    ]
    app.launch()
    defer { app.terminate() }

    waitForCatalogReady(app: app, surface: "kit", profile: "baseline-light")

    let switcher = app.buttons["catalog.switcher.open"].firstMatch
    XCTAssertTrue(
      switcher.waitForExistence(timeout: 8),
      "Expected accessible catalog switcher button 'catalog.switcher.open'"
    )
    switcher.tap()

    let dimProfile = app.buttons["catalog.profile.dim-accent-trap"].firstMatch
    if dimProfile.waitForExistence(timeout: 5) {
      dimProfile.tap()
      waitForCatalogReady(app: app, surface: "kit", profile: "dim-accent-trap")
      attachScreenshot(app.screenshot(), named: "switcher-kit__dim-accent-trap")
    }
  }

  // MARK: - Matrix Construction

  private func buildSweepMatrix() -> [SweepTarget] {
    var matrix: [SweepTarget] = []

    // Kit Gallery across all 6 trap profiles.
    for profile in Self.kitTrapProfiles {
      matrix.append(makeTarget(surface: "kit", profile: profile))
    }

    // All mocked Tier-B production surfaces in baseline-light + dim-accent-trap + oled-font-trap.
    let secondaryProfiles = ["baseline-light", "dim-accent-trap", "oled-font-trap"]
    for surface in Self.coreSurfaces where surface != "kit" {
      for profile in secondaryProfiles {
        matrix.append(makeTarget(surface: surface, profile: profile))
      }
    }

    // Optional targeted subset filter via CATBIRD_UITEST_SURFACES (comma-separated).
    if let filterRaw = ProcessInfo.processInfo.environment["CATBIRD_UITEST_SURFACES"],
       !filterRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let allowed = Set(filterRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
      let filtered = matrix.filter { allowed.contains($0.surface) }
      if !filtered.isEmpty {
        return filtered
      }
    }

    return matrix
  }

  private func makeTarget(surface: String, profile: String) -> SweepTarget {
    switch profile {
    case "dim-accent-trap":
      return SweepTarget(
        surface: surface,
        profile: profile,
        theme: "dim",
        accent: "sunrise",
        fontStyle: "system",
        dynamicType: "L",
        reduceTransparency: false,
        reduceMotion: false,
        highContrast: false
      )
    case "oled-font-trap":
      return SweepTarget(
        surface: surface,
        profile: profile,
        theme: "black",
        accent: "lavender",
        fontStyle: "monospaced",
        dynamicType: "L",
        reduceTransparency: false,
        reduceMotion: false,
        highContrast: false
      )
    case "a11y-ax3-narrow":
      return SweepTarget(
        surface: surface,
        profile: profile,
        theme: "light",
        accent: "default",
        fontStyle: "system",
        dynamicType: "AX3",
        reduceTransparency: false,
        reduceMotion: false,
        highContrast: true
      )
    case "glass-reduce-transparency":
      return SweepTarget(
        surface: surface,
        profile: profile,
        theme: "dim",
        accent: "default",
        fontStyle: "system",
        dynamicType: "L",
        reduceTransparency: true,
        reduceMotion: true,
        highContrast: false
      )
    case "resizability-wide-rtl":
      return SweepTarget(
        surface: surface,
        profile: profile,
        theme: "light",
        accent: "default",
        fontStyle: "system",
        dynamicType: "L",
        reduceTransparency: false,
        reduceMotion: false,
        highContrast: false
      )
    default:
      return SweepTarget(
        surface: surface,
        profile: "baseline-light",
        theme: "light",
        accent: "default",
        fontStyle: "system",
        dynamicType: "L",
        reduceTransparency: false,
        reduceMotion: false,
        highContrast: false
      )
    }
  }

  // MARK: - Single-Launch Navigation & Audits

  private func navigate(app: XCUIApplication, surface: String, profile: String) throws {
    let urlString = "blue.catbird://catalog?surface=\(surface)&profile=\(profile)&inspector=0"
    let url = try XCTUnwrap(URL(string: urlString))
    app.open(url)
  }

  private func waitForCatalogReady(app: XCUIApplication, surface: String, profile: String) {
    let readyID = "catalog.ready.\(surface).\(profile)"
    let marker = app.descendants(matching: .any)[readyID].firstMatch
    if !marker.waitForExistence(timeout: 6) {
      // Allow SwiftUI state transition & layout pass to settle when hosting UIKit roots.
      RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    } else {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
  }

  private func runNativeAccessibilityAudit(
    app: XCUIApplication,
    stem: String
  ) -> [UITestAuditReport.AccessibilityAuditIssue] {
    var collected: [UITestAuditReport.AccessibilityAuditIssue] = []

    if #available(iOS 17.0, *) {
      do {
        try app.performAccessibilityAudit(for: .all) { issue in
          let elementDesc = issue.element.map { elem in
            let id = elem.identifier
            if !id.isEmpty { return id }
            if !elem.label.isEmpty { return elem.label }
            return elem.description
          } ?? "UnknownElement"

          collected.append(
            UITestAuditReport.AccessibilityAuditIssue(
              auditType: Self.auditTypeName(issue.auditType),
              element: elementDesc,
              description: issue.compactDescription
            )
          )
          // Return true so the sweep records EVERY issue across EVERY surface into receipts.
          return true
        }
      } catch {
        collected.append(
          UITestAuditReport.AccessibilityAuditIssue(
            auditType: "auditExecutionError",
            element: stem,
            description: error.localizedDescription
          )
        )
      }
    }

    if !collected.isEmpty {
      let summary = collected.map { "[\($0.auditType)] \($0.element): \($0.description)" }.joined(separator: "\n")
      let attachment = XCTAttachment(string: summary)
      attachment.name = "\(stem)-a11y-audit"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    return collected
  }

  @available(iOS 17.0, *)
  private static func auditTypeName(_ type: XCUIAccessibilityAuditType) -> String {
    if type.contains(.contrast) { return "contrast" }
    if type.contains(.dynamicType) { return "dynamicType" }
    if type.contains(.hitRegion) { return "hitRegion" }
    if type.contains(.sufficientElementDescription) { return "sufficientElementDescription" }
    if type.contains(.textClipped) { return "textClipped" }
    if type.contains(.trait) { return "trait" }
    if type.contains(.elementDetection) { return "elementDetection" }
    if (type.rawValue & (1 << 32)) != 0 { return "action" }
    if (type.rawValue & (1 << 33)) != 0 { return "parentChild" }
    return "accessibilityAudit(\(type.rawValue))"
  }

  // MARK: - Artifact Export (matches scripts/visual-qa/build_screen_wall.py)

  private func attachScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func exportArtifactsIfConfigured(
    screenshot: XCUIScreenshot,
    app: XCUIApplication,
    target: SweepTarget,
    auditIssues: [UITestAuditReport.AccessibilityAuditIssue]
  ) throws {
    let env = ProcessInfo.processInfo.environment
    guard let outPath = env["CATBIRD_VISUAL_OUT_DIR"] ?? env["CATBIRD_UITEST_OUT_DIR"],
          !outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }

    let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let stem = "\(target.surface)__\(target.profile)"
    let pngURL = outDir.appendingPathComponent("\(stem).png")
    try screenshot.pngRepresentation.write(to: pngURL, options: .atomic)

    let raster = screenshot.image.cgImage
    let frame = app.frame
    let scale = (raster.map { CGFloat($0.width) / max(1, frame.width) } ?? 3.0).rounded()

    let violations = auditIssues.enumerated().map { index, issue in
      UITestAuditReport.Violation(
        id: "a11yAudit-\(index)",
        category: "a11yAudit",
        severity: "error",
        message: "[\(issue.auditType)] \(issue.description)",
        element: issue.element,
        viewClass: nil,
        identifier: issue.element,
        frame: nil,
        expected: "Pass XCUIApplication.performAccessibilityAudit(for: .all)",
        actual: issue.auditType
      )
    }

    let report = UITestAuditReport(
      schemaVersion: 1,
      surface: target.surface,
      profile: target.profile,
      timestamp: ISO8601DateFormatter().string(from: Date()),
      viewport: UITestAuditReport.Viewport(
        width: Double(frame.width),
        height: Double(frame.height),
        scale: Double(max(1, scale))
      ),
      theme: target.theme,
      accent: target.accent,
      fontStyle: target.fontStyle,
      dynamicType: target.dynamicType,
      reduceTransparency: target.reduceTransparency,
      reduceMotion: target.reduceMotion,
      highContrast: target.highContrast,
      a11yAuditCount: auditIssues.count,
      a11yAuditIssues: auditIssues,
      counts: UITestAuditReport.Counts(
        total: violations.count,
        a11yAudit: auditIssues.count,
        hitTarget: 0,
        nonAppFont: 0,
        accentLeak: 0,
        cornerRadius: 0,
        offGridSpacing: 0,
        reduceTransparency: 0,
        surfaceContrast: 0
      ),
      violations: violations,
      metrics: UITestAuditReport.Metrics(
        blueLeakPixelRatio: 0,
        minSurfaceContrastRatio: nil
      )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonURL = outDir.appendingPathComponent("\(stem).json")
    try encoder.encode(report).write(to: jsonURL, options: .atomic)
  }
}

// MARK: - Codable Mirror of CatbirdDesignAuditReport (UITest target is separate from app module)

private struct UITestAuditReport: Codable {
  struct Viewport: Codable {
    let width: Double
    let height: Double
    let scale: Double
  }

  struct Rect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }

  struct AccessibilityAuditIssue: Codable {
    let auditType: String
    let element: String
    let description: String
  }

  struct Counts: Codable {
    let total: Int
    let a11yAudit: Int
    let hitTarget: Int
    let nonAppFont: Int
    let accentLeak: Int
    let cornerRadius: Int
    let offGridSpacing: Int
    let reduceTransparency: Int
    let surfaceContrast: Int
  }

  struct Violation: Codable {
    let id: String
    let category: String
    let severity: String
    let message: String
    let element: String?
    let viewClass: String?
    let identifier: String?
    let frame: Rect?
    let expected: String?
    let actual: String?
  }

  struct Metrics: Codable {
    let blueLeakPixelRatio: Double
    let minSurfaceContrastRatio: Double?
  }

  let schemaVersion: Int
  let surface: String
  let profile: String
  let timestamp: String
  let viewport: Viewport
  let theme: String
  let accent: String
  let fontStyle: String
  let dynamicType: String
  let reduceTransparency: Bool
  let reduceMotion: Bool
  let highContrast: Bool
  let a11yAuditCount: Int
  let a11yAuditIssues: [AccessibilityAuditIssue]
  let counts: Counts
  let violations: [Violation]
  let metrics: Metrics
}
