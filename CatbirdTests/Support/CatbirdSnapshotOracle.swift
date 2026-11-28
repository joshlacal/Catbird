//
//  CatbirdSnapshotOracle.swift
//  CatbirdTests
//
//  Zero-external-dependency perceptual PNG snapshot & SSIM diff oracle built on
//  CoreGraphics / ImageIO + UIWindow + UIHostingController + `window.drawHierarchy`.
//
//  Environment variables:
//    CATBIRD_VISUAL_OUT_DIR       Export directory for `<surface>__<profile>.{png,json}`
//    CATBIRD_VISUAL_BASELINE_DIR  Optional golden PNG directory for diffing
//    RECORD_SNAPSHOTS=1           Writes/overwrites baselines in CATBIRD_VISUAL_BASELINE_DIR
//

#if os(iOS) && DEBUG
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import Catbird

// MARK: - Snapshot Oracle

@MainActor
enum CatbirdSnapshotOracle {
  struct Config: Sendable {
    let viewportSize: CGSize
    let scale: CGFloat
    let userInterfaceStyle: UIUserInterfaceStyle
    let contentSizeCategory: UIContentSizeCategory
    let layoutDirection: UITraitEnvironmentLayoutDirection
    let safeAreaInsets: UIEdgeInsets
    let settlePasses: Int
    let settleDelayMilliseconds: UInt64

    init(
      viewportSize: CGSize,
      scale: CGFloat = 2.0,
      userInterfaceStyle: UIUserInterfaceStyle = .light,
      contentSizeCategory: UIContentSizeCategory = .large,
      layoutDirection: UITraitEnvironmentLayoutDirection = .leftToRight,
      safeAreaInsets: UIEdgeInsets = .zero,
      settlePasses: Int = 8,
      settleDelayMilliseconds: UInt64 = 25
    ) {
      self.viewportSize = viewportSize
      self.scale = scale
      self.userInterfaceStyle = userInterfaceStyle
      self.contentSizeCategory = contentSizeCategory
      self.layoutDirection = layoutDirection
      self.safeAreaInsets = safeAreaInsets
      self.settlePasses = settlePasses
      self.settleDelayMilliseconds = settleDelayMilliseconds
    }
  }

  struct Comparison: Sendable, Equatable {
    let matched: Bool
    let ssim: Double
    let pixelDeltaRatio: Double
    let dimensionMismatch: Bool
    let baselineMissing: Bool
    let diffImageURL: URL?
  }

  struct CaptureResult: Sendable {
    let surface: String
    let profile: String
    let pngData: Data
    let imageSize: CGSize
    let auditReport: CatbirdDesignAuditReport
    let comparison: Comparison?
    let pngURL: URL?
    let reportURL: URL?
  }

  enum OracleError: Error, LocalizedError {
    case missingWindowScene
    case hierarchyRenderFailed(String)
    case pngEncodingFailed(String)
    case rasterDecodingFailed(String)

    var errorDescription: String? {
      switch self {
      case .missingWindowScene:
        return "No active UIWindowScene found in test host."
      case .hierarchyRenderFailed(let name):
        return "drawHierarchy(in:afterScreenUpdates:true) returned false for \(name)."
      case .pngEncodingFailed(let name):
        return "Failed to encode PNG data for \(name)."
      case .rasterDecodingFailed(let name):
        return "Failed to decode RGBA pixels for \(name)."
      }
    }
  }

  // MARK: - Environment Paths

  static var outputDirectory: URL? {
    guard let raw = ProcessInfo.processInfo.environment["CATBIRD_VISUAL_OUT_DIR"],
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return URL(fileURLWithPath: raw, isDirectory: true)
  }

  static var baselineDirectory: URL? {
    guard let raw = ProcessInfo.processInfo.environment["CATBIRD_VISUAL_BASELINE_DIR"],
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return URL(fileURLWithPath: raw, isDirectory: true)
  }

  static var isRecordingBaselines: Bool {
    let raw = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"]?.lowercased()
    return raw == "1" || raw == "true" || raw == "yes"
  }

  // MARK: - Hosting, Capture & Audit

  /// Hosts `view` inside a deterministic fixed-size `UIWindow`, renders via
  /// `drawHierarchy(in:afterScreenUpdates:true)`, runs `CatbirdDesignInspector.audit(...)`,
  /// writes `<surface>__<profile>.{png,json}` when `CATBIRD_VISUAL_OUT_DIR` is set, and
  /// compares against golden PNG baselines when `CATBIRD_VISUAL_BASELINE_DIR` is set.
  static func captureAndAudit<V: View>(
    _ view: V,
    config: Config,
    auditContext: CatbirdDesignAuditContext,
    perceptualThreshold: Double = 0.98,
    maxPixelDeltaRatio: Double = 0.005
  ) async throws -> CaptureResult {
    let stem = "\(auditContext.surface)__\(auditContext.profile)"
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first
    else {
      throw OracleError.missingWindowScene
    }

    let releaseAX = AppAccessibility.enable()
    defer { releaseAX() }

    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

    let host = UIHostingController(rootView: view)
    host.overrideUserInterfaceStyle = config.userInterfaceStyle
    host.traitOverrides.preferredContentSizeCategory = config.contentSizeCategory
    host.traitOverrides.layoutDirection = config.layoutDirection
    host.additionalSafeAreaInsets = config.safeAreaInsets

    let container = FixedViewportContainerController(child: host, size: config.viewportSize)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: config.viewportSize)
    window.overrideUserInterfaceStyle = config.userInterfaceStyle
    window.backgroundColor = .systemBackground
    window.rootViewController = container
    window.makeKeyAndVisible()
    defer {
      window.endEditing(true)
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }

    await settle(host: host, container: container, passes: config.settlePasses, delayMS: config.settleDelayMilliseconds)

    let targetView = host.view!
    let format = UIGraphicsImageRendererFormat()
    format.scale = config.scale
    format.opaque = true
    var rendered = false
    let image = UIGraphicsImageRenderer(bounds: targetView.bounds, format: format).image { _ in
      rendered = targetView.drawHierarchy(in: targetView.bounds, afterScreenUpdates: true)
    }
    guard rendered, let cgImage = image.cgImage else {
      throw OracleError.hierarchyRenderFailed(stem)
    }
    guard let pngData = encodePNG(cgImage) else {
      throw OracleError.pngEncodingFailed(stem)
    }

    let axElements = AppAccessibility.elements(in: targetView).map { elem in
      let interactive = elem.traits.contains(.button)
        || elem.traits.contains(.link)
        || elem.traits.contains(.adjustable)
        || elem.traits.contains(.searchField)
      return CatbirdInspectorAccessibilityElement(
        identifier: elem.identifier,
        label: elem.label,
        isInteractive: interactive,
        frame: elem.frame
      )
    }

    let report = CatbirdDesignInspector.audit(
      rootView: targetView,
      context: auditContext,
      renderedImage: cgImage,
      accessibilityElements: axElements
    )

    var writtenPNG: URL?
    var writtenReport: URL?
    if let outDir = outputDirectory {
      try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
      let pngURL = outDir.appendingPathComponent("\(stem).png")
      let jsonURL = outDir.appendingPathComponent("\(stem).json")
      try pngData.write(to: pngURL, options: .atomic)
      try report.write(to: jsonURL)
      writtenPNG = pngURL
      writtenReport = jsonURL
    }

    var comparison: Comparison?
    if let baseDir = baselineDirectory {
      try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
      let baselineURL = baseDir.appendingPathComponent("\(stem).png")
      if isRecordingBaselines {
        try pngData.write(to: baselineURL, options: .atomic)
        comparison = Comparison(
          matched: true,
          ssim: 1.0,
          pixelDeltaRatio: 0.0,
          dimensionMismatch: false,
          baselineMissing: false,
          diffImageURL: nil
        )
      } else if FileManager.default.fileExists(atPath: baselineURL.path),
                let baselineData = try? Data(contentsOf: baselineURL),
                let baselineImage = decodePNG(baselineData) {
        let diffOutputDir = outputDirectory?.appendingPathComponent("diffs", isDirectory: true)
        comparison = try compareImages(
          baseline: baselineImage,
          candidate: cgImage,
          stem: stem,
          perceptualThreshold: perceptualThreshold,
          maxPixelDeltaRatio: maxPixelDeltaRatio,
          diffOutputDirectory: diffOutputDir
        )
      } else {
        comparison = Comparison(
          matched: false,
          ssim: 0.0,
          pixelDeltaRatio: 1.0,
          dimensionMismatch: false,
          baselineMissing: true,
          diffImageURL: nil
        )
      }
    }

    return CaptureResult(
      surface: auditContext.surface,
      profile: auditContext.profile,
      pngData: pngData,
      imageSize: CGSize(width: cgImage.width, height: cgImage.height),
      auditReport: report,
      comparison: comparison,
      pngURL: writtenPNG,
      reportURL: writtenReport
    )
  }

  // MARK: - Perceptual SSIM & Pixel-Diff Engine

  /// Compares two `CGImage` rasters using both pixel absdiff ratio (per-channel tolerance 4/255)
  /// and 8x8 windowed luminance SSIM. Writes an amplified diff heatmap PNG when mismatched.
  nonisolated static func compareImages(
    baseline: CGImage,
    candidate: CGImage,
    stem: String,
    perceptualThreshold: Double = 0.98,
    maxPixelDeltaRatio: Double = 0.005,
    channelTolerance: Int = 4,
    diffOutputDirectory: URL? = nil
  ) throws -> Comparison {
    guard baseline.width == candidate.width, baseline.height == candidate.height else {
      return Comparison(
        matched: false,
        ssim: 0.0,
        pixelDeltaRatio: 1.0,
        dimensionMismatch: true,
        baselineMissing: false,
        diffImageURL: nil
      )
    }

    let width = baseline.width
    let height = baseline.height
    let baseRGBA = try extractRGBA(baseline, stem: "\(stem)-baseline")
    let candRGBA = try extractRGBA(candidate, stem: "\(stem)-candidate")

    let pixelCount = width * height
    var changedPixels = 0
    var baseLuma = [Double](repeating: 0, count: pixelCount)
    var candLuma = [Double](repeating: 0, count: pixelCount)
    var diffRGBA = [UInt8](repeating: 255, count: pixelCount * 4)

    for idx in 0..<pixelCount {
      let off = idx * 4
      let br = Int(baseRGBA[off])
      let bg = Int(baseRGBA[off + 1])
      let bb = Int(baseRGBA[off + 2])
      let cr = Int(candRGBA[off])
      let cg = Int(candRGBA[off + 1])
      let cb = Int(candRGBA[off + 2])

      baseLuma[idx] = 0.299 * Double(br) + 0.587 * Double(bg) + 0.114 * Double(bb)
      candLuma[idx] = 0.299 * Double(cr) + 0.587 * Double(cg) + 0.114 * Double(cb)

      let maxDelta = max(abs(br - cr), max(abs(bg - cg), abs(bb - cb)))
      if maxDelta > channelTolerance {
        changedPixels += 1
        // Amplified magenta heatmap highlight for changed pixels.
        let boost = min(255, maxDelta * 4 + 80)
        diffRGBA[off] = UInt8(boost)
        diffRGBA[off + 1] = 24
        diffRGBA[off + 2] = UInt8(min(255, boost))
        diffRGBA[off + 3] = 255
      } else {
        // Dimmed grayscale backdrop for unchanged context.
        let gray = UInt8(min(255, max(0, Int(candLuma[idx] * 0.35))))
        diffRGBA[off] = gray
        diffRGBA[off + 1] = gray
        diffRGBA[off + 2] = gray
        diffRGBA[off + 3] = 255
      }
    }

    let deltaRatio = pixelCount > 0 ? Double(changedPixels) / Double(pixelCount) : 0
    let ssim = computeWindowedSSIM(baseLuma: baseLuma, candLuma: candLuma, width: width, height: height)
    let matched = ssim >= perceptualThreshold && deltaRatio <= maxPixelDeltaRatio

    var diffURL: URL?
    if !matched, let diffDir = diffOutputDirectory,
       let diffImage = makeCGImage(rgba: diffRGBA, width: width, height: height),
       let diffData = encodePNG(diffImage) {
      try FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true)
      let url = diffDir.appendingPathComponent("\(stem)__diff.png")
      try diffData.write(to: url, options: .atomic)
      diffURL = url
    }

    return Comparison(
      matched: matched,
      ssim: (ssim * 10_000).rounded() / 10_000,
      pixelDeltaRatio: (deltaRatio * 100_000).rounded() / 100_000,
      dimensionMismatch: false,
      baselineMissing: false,
      diffImageURL: diffURL
    )
  }

  /// Standard 8x8 non-overlapping block luminance SSIM (Wang et al., 2004).
  private nonisolated static func computeWindowedSSIM(
    baseLuma: [Double],
    candLuma: [Double],
    width: Int,
    height: Int
  ) -> Double {
    let blockSize = 8
    let c1 = (0.01 * 255.0) * (0.01 * 255.0)
    let c2 = (0.03 * 255.0) * (0.03 * 255.0)

    var ssimSum = 0.0
    var blockCount = 0

    for blockY in stride(from: 0, to: height, by: blockSize) {
      let maxY = min(height, blockY + blockSize)
      for blockX in stride(from: 0, to: width, by: blockSize) {
        let maxX = min(width, blockX + blockSize)
        let count = Double((maxY - blockY) * (maxX - blockX))
        guard count > 0 else { continue }

        var meanX = 0.0
        var meanY = 0.0
        for row in blockY..<maxY {
          let rowOffset = row * width
          for col in blockX..<maxX {
            let idx = rowOffset + col
            meanX += baseLuma[idx]
            meanY += candLuma[idx]
          }
        }
        meanX /= count
        meanY /= count

        var varX = 0.0
        var varY = 0.0
        var covXY = 0.0
        for row in blockY..<maxY {
          let rowOffset = row * width
          for col in blockX..<maxX {
            let idx = rowOffset + col
            let dx = baseLuma[idx] - meanX
            let dy = candLuma[idx] - meanY
            varX += dx * dx
            varY += dy * dy
            covXY += dx * dy
          }
        }
        varX /= count
        varY /= count
        covXY /= count

        let numerator = (2.0 * meanX * meanY + c1) * (2.0 * covXY + c2)
        let denominator = (meanX * meanX + meanY * meanY + c1) * (varX + varY + c2)
        ssimSum += denominator > 0 ? (numerator / denominator) : 1.0
        blockCount += 1
      }
    }

    return blockCount > 0 ? ssimSum / Double(blockCount) : 1.0
  }

  // MARK: - CoreGraphics / ImageIO Utilities

  private nonisolated static func extractRGBA(_ image: CGImage, stem: String) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
      throw OracleError.rasterDecodingFailed(stem)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return bytes
  }

  private nonisolated static func makeCGImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let data = Data(rgba)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: srgb,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  nonisolated static func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  nonisolated static func decodePNG(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func settle<Content: View>(
    host: UIHostingController<Content>,
    container: UIViewController,
    passes: Int,
    delayMS: UInt64
  ) async {
    for _ in 0..<max(1, passes) {
      container.view.setNeedsLayout()
      container.view.layoutIfNeeded()
      host.traitCollection.performAsCurrent {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
      }
      try? await Task.sleep(for: .milliseconds(delayMS))
    }
  }
}

// MARK: - Fixed Viewport Container

/// Containment wrapper guaranteeing exact receiving bounds regardless of physical simulator size.
@MainActor
private final class FixedViewportContainerController: UIViewController {
  private let child: UIViewController
  private let viewportSize: CGSize

  init(child: UIViewController, size: CGSize) {
    self.child = child
    self.viewportSize = size
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(child)
    view.addSubview(child.view)
    child.didMove(toParent: self)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    child.view.frame = CGRect(origin: .zero, size: viewportSize)
  }
}
#endif
