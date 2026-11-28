//
//  CatbirdDesignInspector.swift
//  Catbird
//
//  DEBUG-only runtime design-consistency audit engine.
//  Walks live UIView / CALayer hierarchies and rendered pixels to detect:
//    - Interactive hit targets < 44x44pt (pixel-rounded)
//    - Non-appFont bypasses (under monospaced font trap)
//    - Hardcoded .blue / systemBlue accent leaks (under non-blue accent trap)
//    - Off-scale or non-continuous corner radii and off-4pt-grid spacing
//    - Liquid Glass views missing opaque Reduce Transparency fallbacks & low contrast
//
//  Emits Codable/Sendable `CatbirdDesignAuditReport` JSON consumed by
//  `scripts/visual-qa/build_screen_wall.py` and the live DEBUG overlay HUD.
//

#if DEBUG
import CoreGraphics
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Notification

extension Notification.Name {
  /// Posted to toggle the live DEBUG CatbirdDesignInspector HUD overlay.
  static let catbirdToggleDesignInspector = Notification.Name("CatbirdToggleDesignInspector")
}

// MARK: - Audit Report Schema (matches scripts/visual-qa/build_screen_wall.py)

struct CatbirdDesignAuditReport: Codable, Sendable, Equatable {
  struct Viewport: Codable, Sendable, Equatable {
    let width: Double
    let height: Double
    let scale: Double
  }

  struct Rect: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }

    init(_ cgRect: CGRect) {
      self.x = Double((cgRect.origin.x * 100).rounded() / 100)
      self.y = Double((cgRect.origin.y * 100).rounded() / 100)
      self.width = Double((cgRect.size.width * 100).rounded() / 100)
      self.height = Double((cgRect.size.height * 100).rounded() / 100)
    }

    var cgRect: CGRect {
      CGRect(x: x, y: y, width: width, height: height)
    }
  }

  enum Category: String, Codable, CaseIterable, Sendable {
    case hitTarget
    case nonAppFont
    case accentLeak
    case cornerRadius
    case offGridSpacing
    case reduceTransparency
    case surfaceContrast
    case a11yAudit

    var displayName: String {
      switch self {
      case .hitTarget: return "Hit Target (<44pt)"
      case .nonAppFont: return "Font Bypass"
      case .accentLeak: return "Accent Leak"
      case .cornerRadius: return "Corner Radius"
      case .offGridSpacing: return "Off-4pt Grid"
      case .reduceTransparency: return "Reduce Transparency"
      case .surfaceContrast: return "Surface Contrast"
      case .a11yAudit: return "Accessibility Audit"
      }
    }

    var shortBadge: String {
      switch self {
      case .hitTarget: return "<44"
      case .nonAppFont: return "FONT"
      case .accentLeak: return "BLUE"
      case .cornerRadius: return "RAD"
      case .offGridSpacing: return "4PT"
      case .reduceTransparency: return "GLASS"
      case .surfaceContrast: return "WCAG"
      case .a11yAudit: return "A11Y"
      }
    }
  }

  enum Severity: String, Codable, Sendable {
    case error
    case warning
  }

  struct Violation: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let category: Category
    let severity: Severity
    let message: String
    let element: String?
    let viewClass: String?
    let identifier: String?
    let frame: Rect?
    let expected: String?
    let actual: String?

    init(
      id: String,
      category: Category,
      severity: Severity,
      message: String,
      element: String? = nil,
      viewClass: String?,
      identifier: String?,
      frame: Rect?,
      expected: String?,
      actual: String?
    ) {
      self.id = id
      self.category = category
      self.severity = severity
      self.message = message
      self.element = element ?? identifier ?? viewClass
      self.viewClass = viewClass
      self.identifier = identifier
      self.frame = frame
      self.expected = expected
      self.actual = actual
    }
  }

  struct AccessibilityAuditIssueRecord: Codable, Sendable, Equatable {
    let auditType: String
    let element: String
    let description: String
  }

  struct Counts: Codable, Sendable, Equatable {
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

  struct Metrics: Codable, Sendable, Equatable {
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
  let a11yAuditIssues: [AccessibilityAuditIssueRecord]
  let counts: Counts
  let violations: [Violation]
  let metrics: Metrics

  static func make(
    surface: String,
    profile: String,
    viewport: Viewport,
    theme: String,
    accent: String,
    fontStyle: String,
    dynamicType: String,
    reduceTransparency: Bool,
    reduceMotion: Bool,
    highContrast: Bool,
    violations: [Violation],
    a11yAuditIssues: [AccessibilityAuditIssueRecord] = [],
    metrics: Metrics = Metrics(blueLeakPixelRatio: 0, minSurfaceContrastRatio: nil),
    timestamp: String? = nil
  ) -> CatbirdDesignAuditReport {
    var allViolations = violations
    let hasInlineA11y = violations.contains { $0.category == .a11yAudit }
    if !hasInlineA11y && !a11yAuditIssues.isEmpty {
      for (index, issue) in a11yAuditIssues.enumerated() {
        allViolations.append(
          Violation(
            id: "a11yAudit-\(index)",
            category: .a11yAudit,
            severity: .error,
            message: "[\(issue.auditType)] \(issue.description)",
            element: issue.element,
            viewClass: nil,
            identifier: issue.element,
            frame: nil,
            expected: "Pass XCUIApplication.performAccessibilityAudit",
            actual: issue.auditType
          )
        )
      }
    }

    let hitTarget = allViolations.count { $0.category == .hitTarget }
    let nonAppFont = allViolations.count { $0.category == .nonAppFont }
    let accentLeak = allViolations.count { $0.category == .accentLeak }
    let cornerRadius = allViolations.count { $0.category == .cornerRadius }
    let offGridSpacing = allViolations.count { $0.category == .offGridSpacing }
    let reduceTransparencyCount = allViolations.count { $0.category == .reduceTransparency }
    let surfaceContrast = allViolations.count { $0.category == .surfaceContrast }
    let a11yCount = max(
      a11yAuditIssues.count,
      allViolations.count { $0.category == .a11yAudit }
    )
    let total = allViolations.count

    let resolvedTimestamp = timestamp ?? ISO8601DateFormatter().string(from: Date())
    return CatbirdDesignAuditReport(
      schemaVersion: 1,
      surface: surface,
      profile: profile,
      timestamp: resolvedTimestamp,
      viewport: viewport,
      theme: theme,
      accent: accent,
      fontStyle: fontStyle,
      dynamicType: dynamicType,
      reduceTransparency: reduceTransparency,
      reduceMotion: reduceMotion,
      highContrast: highContrast,
      a11yAuditCount: a11yCount,
      a11yAuditIssues: a11yAuditIssues,
      counts: Counts(
        total: total,
        a11yAudit: a11yCount,
        hitTarget: hitTarget,
        nonAppFont: nonAppFont,
        accentLeak: accentLeak,
        cornerRadius: cornerRadius,
        offGridSpacing: offGridSpacing,
        reduceTransparency: reduceTransparencyCount,
        surfaceContrast: surfaceContrast
      ),
      violations: allViolations,
      metrics: metrics
    )
  }

  func jsonData(prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    if prettyPrinted {
      formatting.insert(.prettyPrinted)
    }
    encoder.outputFormatting = formatting
    return try encoder.encode(self)
  }

  func write(to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try jsonData(prettyPrinted: true)
    try data.write(to: url, options: .atomic)
  }
}

// MARK: - Audit Context

struct CatbirdDesignAuditContext: Sendable, Equatable {
  let surface: String
  let profile: String
  let theme: String
  let accent: String
  let fontStyle: String
  let dynamicType: String
  let reduceTransparency: Bool
  let reduceMotion: Bool
  let highContrast: Bool
  let ignoredIdentifiers: Set<String>

  init(
    surface: String = "screen",
    profile: String = "baseline-light",
    theme: String = "light",
    accent: String = "default",
    fontStyle: String = "system",
    dynamicType: String = "L",
    reduceTransparency: Bool = false,
    reduceMotion: Bool = false,
    highContrast: Bool = false,
    ignoredIdentifiers: Set<String> = []
  ) {
    self.surface = surface
    self.profile = profile
    self.theme = theme
    self.accent = accent
    self.fontStyle = fontStyle
    self.dynamicType = dynamicType
    self.reduceTransparency = reduceTransparency
    self.reduceMotion = reduceMotion
    self.highContrast = highContrast
    self.ignoredIdentifiers = ignoredIdentifiers
  }

  var expectsMonospacedFonts: Bool {
    fontStyle.lowercased() == "monospaced" || profile == "oled-font-trap"
  }

  var expectsNoHardcodedBlue: Bool {
    let normalized = accent.lowercased()
    if profile == "dim-accent-trap" { return true }
    let bluePalettes: Set<String> = ["default", "catbird", "twilight", "midnight"]
    return !bluePalettes.contains(normalized)
  }

  var expectsOpaqueGlassFallback: Bool {
    reduceTransparency || profile == "glass-reduce-transparency"
  }
}

/// Optional accessibility element record (populated from `AppAccessibility.elements(in:)`
/// in hosted unit tests or from UIKit runtime traversal).
struct CatbirdInspectorAccessibilityElement: Sendable {
  let identifier: String?
  let label: String?
  let isInteractive: Bool
  let frame: CGRect

  init(identifier: String?, label: String?, isInteractive: Bool, frame: CGRect) {
    self.identifier = identifier
    self.label = label
    self.isInteractive = isInteractive
    self.frame = frame
  }
}

// MARK: - Color & Contrast Math (Cross-Platform)

enum CatbirdColorMetrics {
  struct RGB: Sendable, Equatable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double
  }

  struct HSV: Sendable, Equatable {
    /// Hue in degrees [0, 360).
    let h: Double
    /// Saturation [0, 1].
    let s: Double
    /// Value [0, 1].
    let v: Double
  }

  static func rgbToHSV(_ rgb: RGB) -> HSV {
    let maxVal = max(rgb.r, max(rgb.g, rgb.b))
    let minVal = min(rgb.r, min(rgb.g, rgb.b))
    let delta = maxVal - minVal

    var hue: Double = 0
    if delta > 0.0001 {
      if maxVal == rgb.r {
        hue = 60.0 * (((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6.0))
      } else if maxVal == rgb.g {
        hue = 60.0 * (((rgb.b - rgb.r) / delta) + 2.0)
      } else {
        hue = 60.0 * (((rgb.r - rgb.g) / delta) + 4.0)
      }
      if hue < 0 { hue += 360.0 }
    }
    let saturation = maxVal > 0.0001 ? (delta / maxVal) : 0
    return HSV(h: hue, s: saturation, v: maxVal)
  }

  /// True when an sRGB color falls in the hardcoded iOS systemBlue / Catbird #5192FF band.
  static func isHardcodedBlueBand(_ rgb: RGB) -> Bool {
    guard rgb.a > 0.25 else { return false }
    let hsv = rgbToHSV(rgb)
    return hsv.h >= 205.0 && hsv.h <= 228.0 && hsv.s > 0.55 && hsv.v > 0.35
  }

  /// WCAG 2.1 relative luminance for sRGB channels in [0, 1].
  static func relativeLuminance(_ rgb: RGB) -> Double {
    func linearize(_ channel: Double) -> Double {
      channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearize(rgb.r) + 0.7152 * linearize(rgb.g) + 0.0722 * linearize(rgb.b)
  }

  static func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
    let l1 = relativeLuminance(first)
    let l2 = relativeLuminance(second)
    let lighter = max(l1, l2)
    let darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)
  }

  static func alphaComposite(foreground: RGB, over background: RGB) -> RGB {
    let alpha = min(1, max(0, foreground.a))
    let inv = 1.0 - alpha
    return RGB(
      r: foreground.r * alpha + background.r * inv,
      g: foreground.g * alpha + background.g * inv,
      b: foreground.b * alpha + background.b * inv,
      a: 1.0
    )
  }
}

// MARK: - iOS Runtime Inspector Engine

#if os(iOS)
@MainActor
enum CatbirdDesignInspector {
  /// View tag reserved for the inspector HUD overlay so audits never flag their own chrome.
  static let excludedOverlayTag = 0x51A7_D1A9

  /// Canonical in-app corner radius scale (CatbirdTokens.Radius).
  static let allowedCornerRadii: [CGFloat] = [4, 8, 12, 16, 24]

  /// Minimum interactive hit target dimension in points.
  static let minHitTarget: CGFloat = ControlHeight.minHitTarget

  /// Threshold ratio of non-media screen pixels in the blue band before reporting a pixel leak.
  static let bluePixelLeakThreshold: Double = 0.0015

  static func audit(
    rootView: UIView,
    context: CatbirdDesignAuditContext,
    renderedImage: CGImage? = nil,
    accessibilityElements: [CatbirdInspectorAccessibilityElement] = [],
    excludedSubtrees: [UIView] = []
  ) -> CatbirdDesignAuditReport {
    let scale = resolvedScale(for: rootView)
    let bounds = rootView.bounds
    let excludedSet = Set(excludedSubtrees.map(ObjectIdentifier.init))

    var violations: [CatbirdDesignAuditReport.Violation] = []
    var hitTargetSeenFrames: [CGRect] = []
    var mediaExclusionRects: [CGRect] = []
    var minContrastRatio: Double?

    let views = visibleViews(in: rootView, excluding: excludedSet)

    // Collect media / avatar rects first so HSV pixel scan masks out photos & user avatars.
    for view in views {
      if isMediaOrPhotoView(view) {
        let frame = view.convert(view.bounds, to: rootView)
        if !frame.isEmpty {
          mediaExclusionRects.append(frame)
        }
      }
    }

    // 1. Hit-target < 44x44pt check (UIControls + interactive accessibility elements)
    checkHitTargets(
      views: views,
      accessibilityElements: accessibilityElements,
      rootView: rootView,
      scale: scale,
      context: context,
      seenFrames: &hitTargetSeenFrames,
      violations: &violations
    )

    // 2. Non-appFont bypass check (active under monospaced font trap)
    if context.expectsMonospacedFonts {
      checkFontBypasses(
        views: views,
        rootView: rootView,
        context: context,
        violations: &violations
      )
    }

    // 3. Hardcoded .blue / accent leak check (active under non-blue accent trap)
    var blueLeakPixelRatio = 0.0
    if context.expectsNoHardcodedBlue {
      checkViewAccentLeaks(
        views: views,
        rootView: rootView,
        context: context,
        violations: &violations
      )
      if let image = renderedImage {
        let scan = scanPixelsForBlueLeak(
          image: image,
          viewportBounds: bounds,
          exclusionRects: mediaExclusionRects
        )
        blueLeakPixelRatio = scan.ratio
        if scan.ratio > bluePixelLeakThreshold {
          let pct = String(format: "%.2f%%", scan.ratio * 100)
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "accentLeak-pixels-\(violations.count)",
              category: .accentLeak,
              severity: .error,
              message: "Rendered pixels contain \(pct) hardcoded blue-band pixels under accent '\(context.accent)'",
              viewClass: "RenderedFrame",
              identifier: context.surface,
              frame: scan.clusterRect.map(CatbirdDesignAuditReport.Rect.init),
              expected: "<= \(String(format: "%.2f%%", bluePixelLeakThreshold * 100)) blue pixels",
              actual: pct
            )
          )
        }
      }
    }

    // 4. Corner radius & off-4pt-grid spacing check
    checkCornerRadii(
      rootView: rootView,
      excluding: excludedSet,
      context: context,
      violations: &violations
    )
    checkOffGridSpacing(
      views: views,
      rootView: rootView,
      context: context,
      violations: &violations
    )

    // 5. Liquid Glass Reduce Transparency & Surface Contrast check
    let effectiveReduceTransparency =
      context.expectsOpaqueGlassFallback || UIAccessibility.isReduceTransparencyEnabled
    if effectiveReduceTransparency {
      checkReduceTransparency(
        views: views,
        rootView: rootView,
        context: context,
        violations: &violations
      )
    }

    minContrastRatio = checkSurfaceContrast(
      views: views,
      rootView: rootView,
      context: context,
      violations: &violations
    )

    return CatbirdDesignAuditReport.make(
      surface: context.surface,
      profile: context.profile,
      viewport: CatbirdDesignAuditReport.Viewport(
        width: Double(bounds.width),
        height: Double(bounds.height),
        scale: Double(scale)
      ),
      theme: context.theme,
      accent: context.accent,
      fontStyle: context.fontStyle,
      dynamicType: context.dynamicType,
      reduceTransparency: effectiveReduceTransparency,
      reduceMotion: context.reduceMotion || UIAccessibility.isReduceMotionEnabled,
      highContrast: context.highContrast || UIAccessibility.isDarkerSystemColorsEnabled,
      violations: violations,
      metrics: CatbirdDesignAuditReport.Metrics(
        blueLeakPixelRatio: (blueLeakPixelRatio * 100_000).rounded() / 100_000,
        minSurfaceContrastRatio: minContrastRatio.map { ($0 * 100).rounded() / 100 }
      )
    )
  }

  /// Captures a `CGImage` of `view` via `drawHierarchy(in:afterScreenUpdates:true)` so iOS 26/27
  /// Liquid Glass & backdrop effects are preserved accurately.
  static func captureHierarchyImage(of view: UIView, scale: CGFloat? = nil) -> CGImage? {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale ?? resolvedScale(for: view)
    format.opaque = false
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
      _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    return image.cgImage
  }

  // MARK: - Traversal & Filtering

  private static func resolvedScale(for view: UIView) -> CGFloat {
    let traitScale = view.traitCollection.displayScale
    if traitScale >= 1 { return traitScale }
    if let windowScale = view.window?.windowScene?.screen.scale, windowScale >= 1 {
      return windowScale
    }
    return 2.0
  }

  private static func visibleViews(in root: UIView, excluding: Set<ObjectIdentifier>) -> [UIView] {
    var result: [UIView] = []
    func visit(_ view: UIView, depth: Int) {
      guard depth < 64 else { return }
      if view.tag == excludedOverlayTag || excluding.contains(ObjectIdentifier(view)) { return }
      if view.isHidden || view.alpha <= 0.01 { return }
      if isSystemChromeClass(view) { return }
      result.append(view)
      for subview in view.subviews {
        visit(subview, depth: depth + 1)
      }
    }
    visit(root, depth: 0)
    return result
  }

  private static func isSystemChromeClass(_ view: UIView) -> Bool {
    let name = NSStringFromClass(type(of: view))
    let ignoredPrefixes = [
      "_UIStatusBar", "UIStatusBar", "_UIScrollViewScrollIndicator",
      "_UIKeyboard", "UIInputSet", "_UIRemoteKeyboard", "_UIBarBackground",
      "_UINavigationBar", "_UITabBar", "_UISearchBar", "UITextSelection"
    ]
    return ignoredPrefixes.contains { name.hasPrefix($0) }
  }

  private static func isMediaOrPhotoView(_ view: UIView) -> Bool {
    if let imageView = view as? UIImageView {
      // Template SF Symbols are tinted chrome, NOT user photos — keep them in accent scan.
      if let image = imageView.image, image.isSymbolImage || image.renderingMode == .alwaysTemplate {
        return false
      }
      return imageView.image != nil
    }
    let name = NSStringFromClass(type(of: view))
    return name.contains("AVPlayer") || name.contains("WKWebView") || name.contains("MTKView")
      || name.contains("SCNView") || name.contains("BirdSpinner")
  }

  private static func isFrameInViewport(_ frame: CGRect, viewport: CGRect) -> Bool {
    guard frame.width > 0.5, frame.height > 0.5 else { return false }
    return frame.intersects(viewport)
  }

  private static func isIgnoredIdentifier(_ identifier: String?, context: CatbirdDesignAuditContext) -> Bool {
    guard let identifier, !identifier.isEmpty else { return false }
    if identifier.hasPrefix("catbird.designInspector.") { return true }
    return context.ignoredIdentifiers.contains(identifier)
  }

  // MARK: - Detector A: Hit Targets (< 44x44pt)

  private static func checkHitTargets(
    views: [UIView],
    accessibilityElements: [CatbirdInspectorAccessibilityElement],
    rootView: UIView,
    scale: CGFloat,
    context: CatbirdDesignAuditContext,
    seenFrames: inout [CGRect],
    violations: inout [CatbirdDesignAuditReport.Violation]
  ) {
    let viewport = rootView.bounds
    let minPixels = minHitTarget * scale

    func recordIfTooSmall(
      frame: CGRect,
      viewClass: String?,
      identifier: String?,
      label: String?
    ) {
      guard isFrameInViewport(frame, viewport: viewport) else { return }
      guard !isIgnoredIdentifier(identifier, context: context) else { return }
      let widthPixels = (frame.width * scale).rounded()
      let heightPixels = (frame.height * scale).rounded()
      guard widthPixels < minPixels || heightPixels < minPixels else { return }

      // Deduplicate identical/nearly-identical interactive element frames.
      let alreadyReported = seenFrames.contains { existing in
        abs(existing.minX - frame.minX) < 2 && abs(existing.minY - frame.minY) < 2
          && abs(existing.width - frame.width) < 2 && abs(existing.height - frame.height) < 2
      }
      guard !alreadyReported else { return }
      seenFrames.append(frame)

      let displayID = identifier ?? label ?? viewClass ?? "InteractiveControl"
      let actualText = String(format: "%.1fx%.1fpt", frame.width, frame.height)
      violations.append(
        CatbirdDesignAuditReport.Violation(
          id: "hitTarget-\(violations.count)",
          category: .hitTarget,
          severity: .error,
          message: "Interactive control '\(displayID)' is \(actualText) (<44x44pt minimum)",
          viewClass: viewClass,
          identifier: identifier ?? label,
          frame: CatbirdDesignAuditReport.Rect(frame),
          expected: ">= 44.0x44.0pt",
          actual: actualText
        )
      )
    }

    for view in views {
      if let control = view as? UIControl, control.isEnabled, control.isUserInteractionEnabled {
        // Skip internal UIKit text-field sub-controls and page controls managed by UIKit.
        if control is UITextField || control is UIPageControl { continue }
        let frame = control.convert(control.bounds, to: rootView)
        recordIfTooSmall(
          frame: frame,
          viewClass: NSStringFromClass(type(of: control)),
          identifier: control.accessibilityIdentifier,
          label: control.accessibilityLabel ?? (control as? UIButton)?.currentTitle
        )
      } else if view.isAccessibilityElement {
        let traits = view.accessibilityTraits
        let isInteractive = traits.contains(.button) || traits.contains(.link)
          || traits.contains(.adjustable)
        if isInteractive {
          let frame = view.convert(view.bounds, to: rootView)
          recordIfTooSmall(
            frame: frame,
            viewClass: NSStringFromClass(type(of: view)),
            identifier: view.accessibilityIdentifier,
            label: view.accessibilityLabel
          )
        }
      }
    }

    for element in accessibilityElements where element.isInteractive {
      recordIfTooSmall(
        frame: element.frame,
        viewClass: "UIAccessibilityElement",
        identifier: element.identifier,
        label: element.label
      )
    }
  }

  // MARK: - Detector B: Non-appFont Bypass (Monospaced Trap)

  private static func checkFontBypasses(
    views: [UIView],
    rootView: UIView,
    context: CatbirdDesignAuditContext,
    violations: inout [CatbirdDesignAuditReport.Violation]
  ) {
    let viewport = rootView.bounds

    func isMonospacedFont(_ font: UIFont) -> Bool {
      if font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) {
        return true
      }
      let family = font.familyName.lowercased()
      let name = font.fontName.lowercased()
      return family.contains("mono") || name.contains("mono")
        || family.contains("menlo") || family.contains("courier")
    }

    func hasVisibleLettersOrDigits(_ text: String?) -> Bool {
      guard let text else { return false }
      return text.unicodeScalars.contains { scalar in
        CharacterSet.alphanumerics.contains(scalar)
      }
    }

    for view in views {
      let frame = view.convert(view.bounds, to: rootView)
      guard isFrameInViewport(frame, viewport: viewport) else { continue }
      guard !isIgnoredIdentifier(view.accessibilityIdentifier, context: context) else { continue }

      if let label = view as? UILabel {
        if let attributed = label.attributedText, attributed.length > 0 {
          var flaggedRun = false
          attributed.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributed.length)
          ) { value, range, stop in
            let snippet = (attributed.string as NSString).substring(with: range)
            guard hasVisibleLettersOrDigits(snippet) else { return }
            if let runFont = value as? UIFont, !isMonospacedFont(runFont) {
              flaggedRun = true
              violations.append(
                CatbirdDesignAuditReport.Violation(
                  id: "nonAppFont-\(violations.count)",
                  category: .nonAppFont,
                  severity: .error,
                  message: "Text '\(snippet.prefix(32))' rendered with non-monospaced font '\(runFont.fontName)' under monospaced font trap (bypasses .appFont)",
                  viewClass: NSStringFromClass(type(of: label)),
                  identifier: label.accessibilityIdentifier ?? String(snippet.prefix(32)),
                  frame: CatbirdDesignAuditReport.Rect(frame),
                  expected: "Monospaced FontManager font (.appFont)",
                  actual: "\(runFont.fontName) (\(Int(runFont.pointSize))pt)"
                )
              )
              stop.pointee = true
            }
          }
          if flaggedRun { continue }
        }
        if hasVisibleLettersOrDigits(label.text), let font = label.font, !isMonospacedFont(font) {
          let preview = String((label.text ?? "").prefix(32))
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "nonAppFont-\(violations.count)",
              category: .nonAppFont,
              severity: .error,
              message: "UILabel '\(preview)' uses '\(font.fontName)' instead of FontManager monospaced font",
              viewClass: NSStringFromClass(type(of: label)),
              identifier: label.accessibilityIdentifier ?? preview,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "Monospaced FontManager font (.appFont)",
              actual: "\(font.fontName) (\(Int(font.pointSize))pt)"
            )
          )
        }
      } else if let textView = view as? UITextView {
        if hasVisibleLettersOrDigits(textView.text), let font = textView.font, !isMonospacedFont(font) {
          let preview = String((textView.text ?? "").prefix(32))
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "nonAppFont-\(violations.count)",
              category: .nonAppFont,
              severity: .error,
              message: "UITextView '\(preview)' uses '\(font.fontName)' instead of FontManager monospaced font",
              viewClass: NSStringFromClass(type(of: textView)),
              identifier: textView.accessibilityIdentifier ?? preview,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "Monospaced FontManager font (AppUIFont)",
              actual: "\(font.fontName) (\(Int(font.pointSize))pt)"
            )
          )
        }
      } else if let textField = view as? UITextField {
        let sample = (textField.text?.isEmpty == false) ? textField.text : textField.placeholder
        if hasVisibleLettersOrDigits(sample), let font = textField.font, !isMonospacedFont(font) {
          let preview = String((sample ?? "").prefix(32))
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "nonAppFont-\(violations.count)",
              category: .nonAppFont,
              severity: .error,
              message: "UITextField '\(preview)' uses '\(font.fontName)' instead of FontManager monospaced font",
              viewClass: NSStringFromClass(type(of: textField)),
              identifier: textField.accessibilityIdentifier ?? preview,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "Monospaced FontManager font (.appFont)",
              actual: "\(font.fontName) (\(Int(font.pointSize))pt)"
            )
          )
        }
      }
    }
  }

  // MARK: - Detector C: Hardcoded .blue / Accent Leaks

  private static func resolveSRGB(_ color: UIColor, traits: UITraitCollection) -> CatbirdColorMetrics.RGB? {
    let resolved = color.resolvedColor(with: traits)
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let converted = resolved.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
          let components = converted.components
    else {
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
      return CatbirdColorMetrics.RGB(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }
    if components.count >= 4 {
      return CatbirdColorMetrics.RGB(
        r: Double(components[0]),
        g: Double(components[1]),
        b: Double(components[2]),
        a: Double(components[3])
      )
    }
    if components.count == 2 {
      let w = Double(components[0])
      return CatbirdColorMetrics.RGB(r: w, g: w, b: w, a: Double(components[1]))
    }
    return nil
  }

  private static func checkViewAccentLeaks(
    views: [UIView],
    rootView: UIView,
    context: CatbirdDesignAuditContext,
    violations: inout [CatbirdDesignAuditReport.Violation]
  ) {
    let viewport = rootView.bounds

    for view in views {
      let frame = view.convert(view.bounds, to: rootView)
      guard isFrameInViewport(frame, viewport: viewport) else { continue }
      guard !isIgnoredIdentifier(view.accessibilityIdentifier, context: context) else { continue }
      let traits = view.traitCollection

      var leakedSource: (property: String, rgb: CatbirdColorMetrics.RGB)?

      if let bgColor = view.backgroundColor,
         let rgb = resolveSRGB(bgColor, traits: traits),
         CatbirdColorMetrics.isHardcodedBlueBand(rgb) {
        leakedSource = ("backgroundColor", rgb)
      } else if let label = view as? UILabel,
                let textColor = label.textColor,
                let rgb = resolveSRGB(textColor, traits: traits),
                CatbirdColorMetrics.isHardcodedBlueBand(rgb) {
        leakedSource = ("textColor", rgb)
      } else if let button = view as? UIButton,
                let rgb = resolveSRGB(button.currentTitleColor, traits: traits),
                CatbirdColorMetrics.isHardcodedBlueBand(rgb) {
        leakedSource = ("buttonTitleColor", rgb)
      } else if let cgBorder = view.layer.borderColor, view.layer.borderWidth > 0,
                let rgb = resolveSRGB(UIColor(cgColor: cgBorder), traits: traits),
                CatbirdColorMetrics.isHardcodedBlueBand(rgb) {
        leakedSource = ("borderColor", rgb)
      }

      if let leak = leakedSource {
        let hex = String(
          format: "#%02X%02X%02X",
          Int((leak.rgb.r * 255).rounded()),
          Int((leak.rgb.g * 255).rounded()),
          Int((leak.rgb.b * 255).rounded())
        )
        violations.append(
          CatbirdDesignAuditReport.Violation(
            id: "accentLeak-\(violations.count)",
            category: .accentLeak,
            severity: .error,
            message: "Hardcoded blue \(hex) in \(leak.property) under accent '\(context.accent)'",
            viewClass: NSStringFromClass(type(of: view)),
            identifier: view.accessibilityIdentifier,
            frame: CatbirdDesignAuditReport.Rect(frame),
            expected: "Active theme accent ('\(context.accent)')",
            actual: hex
          )
        )
      }
    }
  }

  private struct BluePixelScanResult {
    let ratio: Double
    let clusterRect: CGRect?
  }

  private static func scanPixelsForBlueLeak(
    image: CGImage,
    viewportBounds: CGRect,
    exclusionRects: [CGRect]
  ) -> BluePixelScanResult {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, viewportBounds.width > 0, viewportBounds.height > 0 else {
      return BluePixelScanResult(ratio: 0, clusterRect: nil)
    }

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let cgContext = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
      return BluePixelScanResult(ratio: 0, clusterRect: nil)
    }
    cgContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let scaleX = CGFloat(width) / viewportBounds.width
    let scaleY = CGFloat(height) / viewportBounds.height
    let pixelExclusions = exclusionRects.map { rect in
      CGRect(
        x: rect.minX * scaleX,
        y: rect.minY * scaleY,
        width: rect.width * scaleX,
        height: rect.height * scaleY
      )
    }

    // Stride by 2px for fast O(N/4) audit while preserving cluster accuracy.
    let strideStep = max(1, min(width, height) / 300)
    var sampled = 0
    var blueCount = 0
    var minX = Int.max
    var minY = Int.max
    var maxX = 0
    var maxY = 0

    for y in stride(from: 0, to: height, by: strideStep) {
      for x in stride(from: 0, to: width, by: strideStep) {
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
        if pixelExclusions.contains(where: { $0.contains(point) }) {
          continue
        }
        sampled += 1
        let offset = (y * width + x) * 4
        let a = Double(bytes[offset + 3]) / 255.0
        guard a > 0.25 else { continue }
        // Un-premultiply RGB
        let r = min(1.0, (Double(bytes[offset]) / 255.0) / a)
        let g = min(1.0, (Double(bytes[offset + 1]) / 255.0) / a)
        let b = min(1.0, (Double(bytes[offset + 2]) / 255.0) / a)
        let rgb = CatbirdColorMetrics.RGB(r: r, g: g, b: b, a: a)
        if CatbirdColorMetrics.isHardcodedBlueBand(rgb) {
          blueCount += 1
          if x < minX { minX = x }
          if y < minY { minY = y }
          if x > maxX { maxX = x }
          if y > maxY { maxY = y }
        }
      }
    }

    let ratio = sampled > 0 ? Double(blueCount) / Double(sampled) : 0
    let clusterRect: CGRect?
    if blueCount > 0, minX <= maxX, minY <= maxY {
      clusterRect = CGRect(
        x: CGFloat(minX) / scaleX,
        y: CGFloat(minY) / scaleY,
        width: max(4, CGFloat(maxX - minX) / scaleX),
        height: max(4, CGFloat(maxY - minY) / scaleY)
      )
    } else {
      clusterRect = nil
    }
    return BluePixelScanResult(ratio: ratio, clusterRect: clusterRect)
  }

  // MARK: - Detector D: Corner Radius & Off-4pt-Grid Spacing

  private static func checkCornerRadii(
    rootView: UIView,
    excluding: Set<ObjectIdentifier>,
    context: CatbirdDesignAuditContext,
    violations: inout [CatbirdDesignAuditReport.Violation]
  ) {
    let viewport = rootView.bounds
    let rootLayer = rootView.layer

    func visitLayer(_ layer: CALayer, depth: Int) {
      guard depth < 64 else { return }
      if layer.isHidden || layer.opacity <= 0.01 { return }

      if let delegateView = layer.delegate as? UIView {
        if delegateView.tag == excludedOverlayTag || excluding.contains(ObjectIdentifier(delegateView)) {
          return
        }
        if isSystemChromeClass(delegateView) { return }
        if isIgnoredIdentifier(delegateView.accessibilityIdentifier, context: context) { return }
      }

      let frame = layer.convert(layer.bounds, to: rootLayer)
      let radius = layer.cornerRadius
      let drawsRoundedSurface =
        layer.masksToBounds
        || (layer.backgroundColor.map { $0.alpha > 0.01 } ?? false)
        || layer.borderWidth > 0

      if radius > 0.5 && drawsRoundedSurface && isFrameInViewport(frame, viewport: viewport) {
        let minDim = min(frame.width, frame.height)
        let isCapsuleOrCircle = minDim > 0 && abs(radius - (minDim / 2.0)) <= 1.0
        let isAllowedScale = allowedCornerRadii.contains { abs($0 - radius) <= 0.5 }
        let ownerView = layer.delegate as? UIView
        let ownerClass = ownerView.map { NSStringFromClass(type(of: $0)) } ?? NSStringFromClass(type(of: layer))

        if !isCapsuleOrCircle && !isAllowedScale {
          let actual = String(format: "%.1fpt", radius)
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "cornerRadius-scale-\(violations.count)",
              category: .cornerRadius,
              severity: .warning,
              message: "Off-scale cornerRadius \(actual) (allowed: 4, 8, 12, 16, 24, or capsule)",
              viewClass: ownerClass,
              identifier: ownerView?.accessibilityIdentifier,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "Radius token {4, 8, 12, 16, 24} or capsule",
              actual: actual
            )
          )
        } else if !isCapsuleOrCircle && layer.cornerCurve != .continuous {
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "cornerRadius-curve-\(violations.count)",
              category: .cornerRadius,
              severity: .warning,
              message: "Non-continuous circular cornerCurve on \(Int(radius.rounded()))pt radius; use .catbirdClip(_:)",
              viewClass: ownerClass,
              identifier: ownerView?.accessibilityIdentifier,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "CALayerCornerCurve.continuous",
              actual: layer.cornerCurve.rawValue
            )
          )
        }
      }

      for sublayer in layer.sublayers ?? [] {
        visitLayer(sublayer, depth: depth + 1)
      }
    }

    visitLayer(rootLayer, depth: 0)
  }

  private static func isOffFourPointGrid(_ value: CGFloat) -> Bool {
    // Allow 0 and 1-2pt hairlines (`Space.hairline == 2`).
    guard value > 2.5, value < 256 else { return false }
    let remainder = abs(value.truncatingRemainder(dividingBy: 4.0))
    return remainder > 0.5 && (4.0 - remainder) > 0.5
  }

  private static func checkOffGridSpacing(
    views: [UIView],
    rootView: UIView,
    context: CatbirdDesignAuditContext,
    violations: inout [CatbirdDesignAuditReport.Violation]
  ) {
    let viewport = rootView.bounds

    for view in views {
      let frame = view.convert(view.bounds, to: rootView)
      guard isFrameInViewport(frame, viewport: viewport) else { continue }
      guard !isIgnoredIdentifier(view.accessibilityIdentifier, context: context) else { continue }

      if let stack = view as? UIStackView, stack.arrangedSubviews.count > 1 {
        let spacing = stack.spacing
        if spacing != UIStackView.spacingUseDefault && spacing != UIStackView.spacingUseSystem
          && isOffFourPointGrid(spacing) {
          let actual = String(format: "%.1fpt", spacing)
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "offGridSpacing-stack-\(violations.count)",
              category: .offGridSpacing,
              severity: .warning,
              message: "UIStackView spacing \(actual) is off the 4pt grid (use Space.*)",
              viewClass: NSStringFromClass(type(of: stack)),
              identifier: stack.accessibilityIdentifier,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "Multiple of 4pt (Space.*)",
              actual: actual
            )
          )
        }
      }

      if let collection = view as? UICollectionView,
         let flow = collection.collectionViewLayout as? UICollectionViewFlowLayout {
        let values: [(String, CGFloat)] = [
          ("minimumLineSpacing", flow.minimumLineSpacing),
          ("minimumInteritemSpacing", flow.minimumInteritemSpacing),
          ("sectionInset.left", flow.sectionInset.left),
          ("sectionInset.right", flow.sectionInset.right)
        ]
        for (prop, value) in values where isOffFourPointGrid(value) {
          let actual = String(format: "%.1fpt", value)
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "offGridSpacing-flow-\(violations.count)",
              category: .offGridSpacing,
              severity: .warning,
              message: "FlowLayout \(prop)=\(actual) is off the 4pt grid",
              viewClass: NSStringFromClass(type(of: collection)),
              identifier: collection.accessibilityIdentifier,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "Multiple of 4pt (Space.*)",
              actual: actual
            )
          )
        }
      }
    }
  }

  // MARK: - Detector E: Liquid Glass Reduce Transparency & Surface Contrast

  private static func checkReduceTransparency(
    views: [UIView],
    rootView: UIView,
    context: CatbirdDesignAuditContext,
    violations: inout [CatbirdDesignAuditReport.Violation]
  ) {
    let viewport = rootView.bounds

    for view in views {
      let frame = view.convert(view.bounds, to: rootView)
      guard frame.width > 4, frame.height > 4, isFrameInViewport(frame, viewport: viewport) else {
        continue
      }
      guard !isIgnoredIdentifier(view.accessibilityIdentifier, context: context) else { continue }

      if let visualEffectView = view as? UIVisualEffectView, let effect = visualEffectView.effect {
        let effectClass = NSStringFromClass(type(of: effect))
        let isBlurOrGlass = effect is UIBlurEffect || effectClass.contains("Glass")
        guard isBlurOrGlass else { continue }

        let bgAlpha = visualEffectView.backgroundColor.flatMap {
          resolveSRGB($0, traits: visualEffectView.traitCollection)?.a
        } ?? 0
        let contentAlpha = visualEffectView.contentView.backgroundColor.flatMap {
          resolveSRGB($0, traits: visualEffectView.traitCollection)?.a
        } ?? 0

        if max(bgAlpha, contentAlpha) < 0.95 {
          violations.append(
            CatbirdDesignAuditReport.Violation(
              id: "reduceTransparency-\(violations.count)",
              category: .reduceTransparency,
              severity: .error,
              message: "Visual effect '\(effectClass)' lacks opaque fallback while Reduce Transparency is enabled",
              viewClass: NSStringFromClass(type(of: visualEffectView)),
              identifier: visualEffectView.accessibilityIdentifier,
              frame: CatbirdDesignAuditReport.Rect(frame),
              expected: "Opaque surface fill (.catbirdGlass Reduce Transparency fallback)",
              actual: "\(effectClass) (alpha=\(String(format: "%.2f", max(bgAlpha, contentAlpha))))"
            )
          )
        }
      }
    }
  }

  private static func checkSurfaceContrast(
    views: [UIView],
    rootView: UIView,
    context: CatbirdDesignAuditContext,
    violations: inout [CatbirdDesignAuditReport.Violation]
  ) -> Double? {
    let viewport = rootView.bounds
    let canvasRGB = resolveOpaqueBackground(for: rootView)
      ?? CatbirdColorMetrics.RGB(r: context.theme == "light" ? 1 : 0, g: context.theme == "light" ? 1 : 0, b: context.theme == "light" ? 1 : 0, a: 1)

    var minRatio: Double?

    for view in views {
      guard let label = view as? UILabel,
            let text = label.text,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let textColor = label.textColor
      else { continue }

      let frame = label.convert(label.bounds, to: rootView)
      guard isFrameInViewport(frame, viewport: viewport) else { continue }
      guard !isIgnoredIdentifier(label.accessibilityIdentifier, context: context) else { continue }

      guard let fgRaw = resolveSRGB(textColor, traits: label.traitCollection) else { continue }
      let bg = resolveOpaqueBackground(for: label) ?? canvasRGB
      let fg = CatbirdColorMetrics.alphaComposite(foreground: fgRaw, over: bg)
      let ratio = CatbirdColorMetrics.contrastRatio(fg, bg)

      if let existing = minRatio {
        minRatio = min(existing, ratio)
      } else {
        minRatio = ratio
      }

      let pointSize = label.font?.pointSize ?? 15
      let isBold = label.font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
      let isLargeText = pointSize >= 18 || (isBold && pointSize >= 14)
      let minimumRequired = isLargeText ? 3.0 : 4.5

      if ratio < minimumRequired {
        let preview = String(text.prefix(28))
        violations.append(
          CatbirdDesignAuditReport.Violation(
            id: "surfaceContrast-\(violations.count)",
            category: .surfaceContrast,
            severity: ratio < 2.5 ? .error : .warning,
            message: "Label '\(preview)' contrast ratio \(String(format: "%.2f", ratio)):1 is below WCAG AA (\(String(format: "%.1f", minimumRequired)):1)",
            viewClass: NSStringFromClass(type(of: label)),
            identifier: label.accessibilityIdentifier ?? preview,
            frame: CatbirdDesignAuditReport.Rect(frame),
            expected: ">= \(String(format: "%.1f", minimumRequired)):1",
            actual: "\(String(format: "%.2f", ratio)):1"
          )
        )
      }
    }

    return minRatio
  }

  private static func resolveOpaqueBackground(for view: UIView) -> CatbirdColorMetrics.RGB? {
    var cursor: UIView? = view
    while let current = cursor {
      if let bg = current.backgroundColor,
         let rgb = resolveSRGB(bg, traits: current.traitCollection),
         rgb.a > 0.92 {
        return rgb
      }
      cursor = current.superview
    }
    return nil
  }
}
#endif
#endif
