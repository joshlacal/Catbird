//
//  DesignConsistencySnapshotTests.swift
//  CatbirdTests
//
//  Tier-1 deterministic visual snapshot & runtime design-inspector suite.
//  Runs in-process across all 6 Orthogonal Trap Profiles (`CatbirdTrapProfile.allCases`)
//  against Kit primitives and mocked offline production surfaces (`CatbirdCatalogSurface`),
//  exporting `<surface>__<profile>.{png,json}` receipts when `CATBIRD_VISUAL_OUT_DIR` is set.
//

#if os(iOS) && DEBUG
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Design consistency visual & runtime audit", .serialized)
@MainActor
struct DesignConsistencySnapshotTests {

  // MARK: - 1. Kit Gallery Across All 6 Orthogonal Trap Profiles

  @Test("Kit Gallery renders cleanly across all 6 orthogonal trap profiles")
  func kitGalleryAcrossAllSixTrapProfiles() async throws {
    let initialConfig = CatbirdCatalogLaunchConfig(
      surface: .kit,
      profile: .baselineLight,
      inspectorEnabled: false,
      disableAnimations: true,
      hideChrome: true
    )
    let session = try await CatbirdCatalogEnvironment.makeSession(for: initialConfig, strictOffline: true)
    defer {
      FontManager.overrideContentSizeCategory = nil
      session.cleanup()
    }

    for profile in selectedProfiles() {
      let result = try await renderAndAudit(
        surface: .kit,
        profile: profile,
        session: session
      )

      #expect(!result.pngData.isEmpty, "kit__\(profile.rawValue) produced empty PNG")
      #expect(result.imageSize.width > 0 && result.imageSize.height > 0)

      // Kit primitives must uphold core runtime invariants across every trap profile.
      let report = result.auditReport
      #expect(
        report.counts.hitTarget == 0,
        "kit__\(profile.rawValue) has <44pt hit targets: \(describe(report.violations, category: .hitTarget))"
      )
      #expect(
        report.counts.accentLeak == 0,
        "kit__\(profile.rawValue) leaked hardcoded blue: \(describe(report.violations, category: .accentLeak))"
      )
      #expect(
        report.counts.reduceTransparency == 0,
        "kit__\(profile.rawValue) leaked translucent glass under Reduce Transparency: \(describe(report.violations, category: .reduceTransparency))"
      )

      verifyBaselineIfPresent(result)
    }
  }

  // MARK: - 2. Full Offline Catalog Surface × Trap Profile Matrix

  @Test("Offline catalog surfaces render & emit visual QA receipts across trap profiles")
  func offlineCatalogSurfacesMatrix() async throws {
    let surfaces = selectedSurfaces().filter { $0 != .kit }
    guard !surfaces.isEmpty else { return }

    let initialConfig = CatbirdCatalogLaunchConfig(
      surface: surfaces[0],
      profile: .baselineLight,
      inspectorEnabled: false,
      disableAnimations: true,
      hideChrome: true
    )
    let session = try await CatbirdCatalogEnvironment.makeSession(for: initialConfig, strictOffline: true)
    defer {
      FontManager.overrideContentSizeCategory = nil
      session.cleanup()
    }

    let strictAudit = ProcessInfo.processInfo.environment["CATBIRD_STRICT_DESIGN_AUDIT"] == "1"
    var strictFailures: [String] = []

    for surface in surfaces {
      for profile in selectedProfiles() {
        let result = try await renderAndAudit(
          surface: surface,
          profile: profile,
          session: session
        )
        let stem = "\(surface.rawValue)__\(profile.rawValue)"
        #expect(!result.pngData.isEmpty, "\(stem) produced empty PNG")
        #expect(result.imageSize.width > 0 && result.imageSize.height > 0)

        verifyBaselineIfPresent(result)

        if strictAudit && result.auditReport.counts.total > 0 {
          strictFailures.append("\(stem): \(result.auditReport.counts.total) violation(s)")
        }
      }
    }

    if strictAudit {
      #expect(
        strictFailures.isEmpty,
        "Strict design audit violations: \(strictFailures.joined(separator: "; "))"
      )
    }
  }

  // MARK: - 3. Synthetic Detector Proofs (Verifies Every Inspector Check Fires & Clears)

  @Test("Hit-target detector flags 32x32 UIButton and passes 44x44 UIButton")
  func hitTargetDetectorFlagsUndersizedButtonAndPasses44ptControl() {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    let smallButton = UIButton(frame: CGRect(x: 16, y: 16, width: 32, height: 32))
    smallButton.accessibilityIdentifier = "fixture.smallButton"
    smallButton.setTitle("X", for: .normal)
    container.addSubview(smallButton)

    let validButton = UIButton(frame: CGRect(x: 16, y: 80, width: 44, height: 44))
    validButton.accessibilityIdentifier = "fixture.validButton"
    validButton.setTitle("OK", for: .normal)
    container.addSubview(validButton)

    let report = CatbirdDesignInspector.audit(
      rootView: container,
      context: CatbirdDesignAuditContext(surface: "synthetic-hit", profile: "baseline-light")
    )

    #expect(report.counts.hitTarget == 1)
    #expect(report.violations.first?.identifier == "fixture.smallButton")
  }

  @Test("Font-bypass detector flags system font and passes monospaced font under oled-font-trap")
  func fontBypassDetectorFlagsNonMonospacedLabelUnderOledFontTrap() {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    container.backgroundColor = .black

    let bypassedLabel = UILabel(frame: CGRect(x: 16, y: 16, width: 280, height: 24))
    bypassedLabel.text = "Hardcoded raw system font"
    bypassedLabel.font = UIFont.systemFont(ofSize: 16)
    bypassedLabel.textColor = .white
    bypassedLabel.accessibilityIdentifier = "fixture.rawFontLabel"
    container.addSubview(bypassedLabel)

    let compliantLabel = UILabel(frame: CGRect(x: 16, y: 56, width: 280, height: 24))
    compliantLabel.text = "FontManager monospaced text"
    compliantLabel.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    compliantLabel.textColor = .white
    compliantLabel.accessibilityIdentifier = "fixture.monoLabel"
    container.addSubview(compliantLabel)

    let report = CatbirdDesignInspector.audit(
      rootView: container,
      context: CatbirdDesignAuditContext(
        surface: "synthetic-font",
        profile: "oled-font-trap",
        theme: "black",
        accent: "lavender",
        fontStyle: "monospaced"
      )
    )

    #expect(report.counts.nonAppFont == 1)
    #expect(report.violations.first { $0.category == .nonAppFont }?.identifier == "fixture.rawFontLabel")
  }

  @Test("Accent-leak detector flags hardcoded blue under sunrise accent and masks out user photos")
  func accentLeakDetectorFlagsHardcodedBlueViewAndPixelsAndIgnoresPhotos() throws {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    container.backgroundColor = UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)

    let leakedView = UIView(frame: CGRect(x: 16, y: 16, width: 64, height: 48))
    leakedView.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    leakedView.accessibilityIdentifier = "fixture.hardcodedBlue"
    container.addSubview(leakedView)

    let compliantView = UIView(frame: CGRect(x: 96, y: 16, width: 64, height: 48))
    compliantView.backgroundColor = UIColor(red: 1.0, green: 0.58, blue: 0.37, alpha: 1.0)
    compliantView.accessibilityIdentifier = "fixture.sunriseAccent"
    container.addSubview(compliantView)

    let renderer = UIGraphicsImageRenderer(size: container.bounds.size)
    let raster = renderer.image { ctx in
      container.layer.render(in: ctx.cgContext)
    }
    let cgImage = try #require(raster.cgImage)

    let report = CatbirdDesignInspector.audit(
      rootView: container,
      context: CatbirdDesignAuditContext(
        surface: "synthetic-accent",
        profile: "dim-accent-trap",
        theme: "dim",
        accent: "sunrise"
      ),
      renderedImage: cgImage
    )

    #expect(report.counts.accentLeak >= 1)
    #expect(report.metrics.blueLeakPixelRatio > CatbirdDesignInspector.bluePixelLeakThreshold)
    #expect(report.violations.contains { $0.identifier == "fixture.hardcodedBlue" })
    #expect(!report.violations.contains { $0.identifier == "fixture.sunriseAccent" })
  }

  @Test("Corner-radius and off-4pt-grid detectors flag raw drift and pass CatbirdTokens")
  func cornerRadiusAndOffGridSpacingDetectorsFlagDriftAndPassCatbirdTokens() {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    container.backgroundColor = .white

    let badCard = UIView(frame: CGRect(x: 16, y: 16, width: 120, height: 60))
    badCard.backgroundColor = .lightGray
    badCard.layer.cornerRadius = 10
    badCard.layer.cornerCurve = .circular
    badCard.layer.masksToBounds = true
    badCard.accessibilityIdentifier = "fixture.badRadiusCard"
    container.addSubview(badCard)

    let goodCard = UIView(frame: CGRect(x: 152, y: 16, width: 120, height: 60))
    goodCard.backgroundColor = .lightGray
    goodCard.layer.cornerRadius = Radius.md.value
    goodCard.layer.cornerCurve = .continuous
    goodCard.layer.masksToBounds = true
    goodCard.accessibilityIdentifier = "fixture.goodRadiusCard"
    container.addSubview(goodCard)

    let badStack = UIStackView(arrangedSubviews: [UIView(), UIView()])
    badStack.frame = CGRect(x: 16, y: 96, width: 200, height: 48)
    badStack.spacing = 6
    badStack.accessibilityIdentifier = "fixture.offGridStack"
    container.addSubview(badStack)

    let goodStack = UIStackView(arrangedSubviews: [UIView(), UIView()])
    goodStack.frame = CGRect(x: 16, y: 160, width: 200, height: 48)
    goodStack.spacing = Space.sm
    goodStack.accessibilityIdentifier = "fixture.onGridStack"
    container.addSubview(goodStack)

    let report = CatbirdDesignInspector.audit(
      rootView: container,
      context: CatbirdDesignAuditContext(surface: "synthetic-geometry", profile: "baseline-light")
    )

    #expect(report.counts.cornerRadius == 1)
    #expect(report.violations.contains { $0.category == .cornerRadius && $0.identifier == "fixture.badRadiusCard" })
    #expect(report.counts.offGridSpacing == 1)
    #expect(report.violations.contains { $0.category == .offGridSpacing && $0.identifier == "fixture.offGridStack" })
  }

  @Test("Reduce-transparency and contrast detectors flag unguarded glass and low-contrast labels")
  func reduceTransparencyAndSurfaceContrastDetectorsFlagFailuresAndPassCompliantViews() {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    container.backgroundColor = .white

    let unguardedBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    unguardedBlur.frame = CGRect(x: 16, y: 16, width: 200, height: 48)
    unguardedBlur.accessibilityIdentifier = "fixture.unguardedBlur"
    container.addSubview(unguardedBlur)

    let lowContrastLabel = UILabel(frame: CGRect(x: 16, y: 80, width: 240, height: 24))
    lowContrastLabel.text = "Low contrast caption"
    lowContrastLabel.textColor = UIColor(white: 0.85, alpha: 1.0)
    lowContrastLabel.font = UIFont.systemFont(ofSize: 14)
    lowContrastLabel.accessibilityIdentifier = "fixture.lowContrast"
    container.addSubview(lowContrastLabel)

    let highContrastLabel = UILabel(frame: CGRect(x: 16, y: 120, width: 240, height: 24))
    highContrastLabel.text = "Readable body text"
    highContrastLabel.textColor = .black
    highContrastLabel.font = UIFont.systemFont(ofSize: 16)
    highContrastLabel.accessibilityIdentifier = "fixture.highContrast"
    container.addSubview(highContrastLabel)

    let report = CatbirdDesignInspector.audit(
      rootView: container,
      context: CatbirdDesignAuditContext(
        surface: "synthetic-glass-contrast",
        profile: "glass-reduce-transparency",
        theme: "light",
        reduceTransparency: true
      )
    )

    #expect(report.counts.reduceTransparency == 1)
    #expect(report.violations.contains { $0.identifier == "fixture.unguardedBlur" })
    #expect(report.counts.surfaceContrast == 1)
    #expect(report.violations.contains { $0.identifier == "fixture.lowContrast" })
    #expect(!report.violations.contains { $0.identifier == "fixture.highContrast" })
  }

  @Test("Snapshot oracle computes SSIM 1.0 for identical images, flags visual diffs, and round-trips report JSON")
  func snapshotOracleDetectsVisualDiffAndRoundTripsAuditReportJSON() throws {
    let size = CGSize(width: 128, height: 128)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1

    let baseImg = try #require(
      UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        UIColor.white.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        UIColor.darkGray.setFill()
        ctx.fill(CGRect(x: 16, y: 16, width: 96, height: 32))
      }.cgImage
    )

    let identical = try CatbirdSnapshotOracle.compareImages(
      baseline: baseImg,
      candidate: baseImg,
      stem: "oracle-identical"
    )
    #expect(identical.matched)
    #expect(identical.ssim == 1.0)
    #expect(identical.pixelDeltaRatio == 0.0)

    let alteredImg = try #require(
      UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        UIColor.white.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        UIColor.systemRed.setFill()
        ctx.fill(CGRect(x: 16, y: 16, width: 96, height: 64))
      }.cgImage
    )

    let tempDiffDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("catbird-oracle-diff-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDiffDir) }

    let diffed = try CatbirdSnapshotOracle.compareImages(
      baseline: baseImg,
      candidate: alteredImg,
      stem: "oracle-altered",
      diffOutputDirectory: tempDiffDir
    )
    #expect(!diffed.matched)
    #expect(diffed.pixelDeltaRatio > 0.1)
    #expect(diffed.ssim < 0.98)
    let diffURL = try #require(diffed.diffImageURL)
    #expect(FileManager.default.fileExists(atPath: diffURL.path))

    // Verify JSON receipt schema round-trips cleanly.
    let report = CatbirdDesignAuditReport.make(
      surface: "kit",
      profile: "baseline-light",
      viewport: CatbirdDesignAuditReport.Viewport(width: 402, height: 874, scale: 2),
      theme: "light",
      accent: "default",
      fontStyle: "system",
      dynamicType: "L",
      reduceTransparency: false,
      reduceMotion: false,
      highContrast: false,
      violations: []
    )
    let encoded = try report.jsonData(prettyPrinted: true)
    let decoded = try JSONDecoder().decode(CatbirdDesignAuditReport.self, from: encoded)
    #expect(decoded == report)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.counts.total == 0)
  }

  // MARK: - Helpers

  private func renderAndAudit(
    surface: CatbirdCatalogSurface,
    profile: CatbirdTrapProfile,
    session: CatbirdCatalogSession
  ) async throws -> CatbirdSnapshotOracle.CaptureResult {
    let config = CatbirdCatalogLaunchConfig(
      surface: surface,
      profile: profile,
      inspectorEnabled: false,
      disableAnimations: true,
      hideChrome: true
    )
    session.apply(config: config)
    FontManager.overrideContentSizeCategory = profile.uiContentSizeCategory
    session.appState.fontManager.refreshContentSizeCategory()

    let themeLabel: String
    if config.theme == "dark" {
      themeLabel = config.darkThemeMode == "black" ? "black" : "dim"
    } else {
      themeLabel = config.theme
    }

    let oracleConfig = CatbirdSnapshotOracle.Config(
      viewportSize: profile.viewportSize,
      scale: 2.0,
      userInterfaceStyle: config.preferredColorScheme == .dark ? .dark : .light,
      contentSizeCategory: profile.uiContentSizeCategory,
      layoutDirection: profile.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight,
      safeAreaInsets: profile.uiSafeAreaInsets
    )

    let auditContext = CatbirdDesignAuditContext(
      surface: surface.rawValue,
      profile: profile.rawValue,
      theme: themeLabel,
      accent: config.accentColor,
      fontStyle: config.fontStyle,
      dynamicType: String(describing: config.dynamicType),
      reduceTransparency: config.reduceTransparency,
      reduceMotion: config.reduceMotion,
      highContrast: config.increaseContrast
    )

    let rootView = CatbirdCatalogSurfaceView(
      surface: surface,
      config: config,
      session: session
    )
    .environment(\.dynamicTypeSize, config.dynamicType)
    .environment(\.layoutDirection, config.layoutDirection)

    return try await CatbirdSnapshotOracle.captureAndAudit(
      rootView,
      config: oracleConfig,
      auditContext: auditContext
    )
  }

  private func verifyBaselineIfPresent(_ result: CatbirdSnapshotOracle.CaptureResult) {
    guard let comparison = result.comparison, !comparison.baselineMissing else { return }
    let stem = "\(result.surface)__\(result.profile)"
    #expect(
      comparison.matched,
      "Visual snapshot regression for \(stem): SSIM=\(comparison.ssim), delta=\(String(format: "%.3f%%", comparison.pixelDeltaRatio * 100)), dimensionMismatch=\(comparison.dimensionMismatch), diff=\(comparison.diffImageURL?.path ?? "none")"
    )
  }

  private func selectedProfiles() -> [CatbirdTrapProfile] {
    if let raw = ProcessInfo.processInfo.environment["CATBIRD_SNAPSHOT_PROFILES"],
       !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let requested = raw.split(separator: ",").compactMap {
        CatbirdTrapProfile(rawValue: $0.trimmingCharacters(in: .whitespaces))
      }
      if !requested.isEmpty { return requested }
    }
    return CatbirdTrapProfile.allCases
  }

  private func selectedSurfaces() -> [CatbirdCatalogSurface] {
    if let raw = ProcessInfo.processInfo.environment["CATBIRD_SNAPSHOT_SURFACES"],
       !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let requested = raw.split(separator: ",").compactMap {
        CatbirdCatalogSurface.parse(String($0))
      }
      if !requested.isEmpty { return requested }
    }
    return CatbirdCatalogSurface.allCases
  }

  private func describe(
    _ violations: [CatbirdDesignAuditReport.Violation],
    category: CatbirdDesignAuditReport.Category
  ) -> String {
    violations
      .filter { $0.category == category }
      .map { "\($0.identifier ?? $0.viewClass ?? "View"): \($0.message)" }
      .joined(separator: " | ")
  }
}
#endif
