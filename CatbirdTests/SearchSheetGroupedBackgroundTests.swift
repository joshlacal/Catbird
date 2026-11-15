import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// The Filters and Save Search sheets draw their `Form` with the grouped pair: rows that stand out from
/// the sheet behind them in Light, Dim and Black.
@Suite("Search sheet grouped backgrounds", .serialized)
@MainActor
struct SearchSheetGroupedBackgroundTests {
  @Test("Light keeps the system's white rows on the gray sheet; Dim and Black raise rows above the sheet")
  func groupedPairInEveryMode() {
    let theme = ThemeManager(fontManager: FontManager())
    let light = UITraitCollection(userInterfaceStyle: .light)
    let lightRow = Self.rgb(.dynamicGroupedRowBackground(theme, currentScheme: .light), light)
    let lightSheet = Self.rgb(.dynamicGroupedBackground(theme, currentScheme: .light), light)
    #expect(lightRow == Self.rgb(Color(uiColor: .secondarySystemGroupedBackground), light))
    #expect(lightSheet == Self.rgb(Color(uiColor: .systemGroupedBackground), light))
    #expect(Self.luminance(lightRow) > Self.luminance(lightSheet))

    let dark = UITraitCollection(userInterfaceStyle: .dark)
    for mode in [ThemeManager.DarkThemeMode.dim, .black] {
      theme.darkThemeMode = mode
      let row = Self.rgb(.dynamicGroupedRowBackground(theme, currentScheme: .dark), dark)
      let sheet = Self.rgb(.dynamicGroupedBackground(theme, currentScheme: .dark), dark)
      #expect(Self.luminance(row) > Self.luminance(sheet), "\(mode): row \(row) on sheet \(sheet)")
    }
  }

  @Test("The rendered Filters sheet shows rows lighter than the sheet in Light and Dim")
  func renderedFiltersSheet() async throws {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://search-sheet-background.invalid")))
    let appState = AppState(userDID: "did:plc:searchsheetbackground", client: client,
      regulatoryChecker: SheetBackgroundAgeChecker())
    let theme = appState.themeManager
    let previous = (theme.colorSchemeOverride, theme.darkThemeMode)
    defer {
      theme.colorSchemeOverride = previous.0
      theme.darkThemeMode = previous.1
      appState.cleanup()
    }
    theme.darkThemeMode = .dim

    for scheme in [ColorScheme.light, .dark] {
      theme.colorSchemeOverride = scheme
      let sheet = SearchFiltersSheet(initialState: SearchFilterState(), onApply: { _ in })
        .environment(appState)
        .fontManager(appState.fontManager)
        .environment(\.colorScheme, scheme)
      let (row, background, png, detail) = try await Self.sampleFirstRow(of: sheet, style: scheme == .light ? .light : .dark)
      Attachment.record(png, named: "search-filters-sheet-\(scheme == .light ? "light" : "dim").png")
      #expect(Self.luminance(row) > Self.luminance(background) + 0.02,
        "\(scheme): row \(row) must stand out from the sheet \(background); \(detail)")
      if scheme == .light {
        #expect(Self.luminance(row) > 0.98, "Light rows are the system's white grouped rows, got \(row)")
      }
    }
  }

  @Test("Both Search sheets use the grouped pair, not a plain background")
  func sheetsUseTheGroupedPair() throws {
    for path in [
      "Catbird/Features/Search/Views/FilterViews/SearchFiltersSheet.swift",
      "Catbird/Features/Search/Views/Components/SaveSearchSheet.swift"
    ] {
      let source = try Self.sourceFile(path)
      #expect(source.contains(".listRowBackground(Color.dynamicGroupedRowBackground("), "\(path)")
      #expect(source.contains(".background(Color.dynamicGroupedBackground("), "\(path)")
      #expect(!source.contains(".listRowBackground(Color.elevatedBackground("), "\(path)")
      #expect(!source.contains(".background(Color.dynamicBackground("), "\(path)")
    }
  }

  // MARK: Helpers

  /// The color's sRGB components, 0–255, for these traits.
  private static func rgb(_ color: Color, _ traits: UITraitCollection) -> [Double] {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue].map { (Double($0) * 255).rounded() }
  }

  private static func luminance(_ rgb: [Double]) -> Double {
    (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255
  }

  /// Renders `content` in a window and returns the color just inside the first list row's leading
  /// edge, the sheet color in the margin beside it, and the rendering.
  private static func sampleFirstRow<Content: View>(
    of content: Content, style: UIUserInterfaceStyle
  ) async throws -> (row: [Double], background: [Double], png: Data, detail: String) {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    window.overrideUserInterfaceStyle = style
    let controller = UIHostingController(rootView: content)
    window.rootViewController = controller
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }

    var cellFrames: [CGRect] = []
    for _ in 0..<40 where cellFrames.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
      window.layoutIfNeeded()
      cellFrames = visibleCellFrames(in: window)
    }
    let cell = try #require(cellFrames.first, "The Form never laid out a row")
    try #require(cell.minX >= 8, "Rows must be inset from the sheet edge, got \(cell)")
    try await Task.sleep(for: .milliseconds(150))

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
      _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let cgImage = try #require(image.cgImage)
    let row = try pixel(cgImage, x: Int(cell.minX) + 3, y: Int(cell.midY))
    let background = try pixel(cgImage, x: Int(cell.minX / 2), y: Int(cell.midY))
    let detail = "sampled x=\(Int(cell.minX) + 3) and x=\(Int(cell.minX / 2)) at y=\(Int(cell.midY)); cells \(cellFrames.prefix(4))"
    return (row, background, image.pngData() ?? Data(), detail)
  }

  /// Frames, in window coordinates and top to bottom, of the on-screen rows holding a text field
  /// (the sheet's first sections). Section headers are list cells too, drawn on the sheet color.
  private static func visibleCellFrames(in window: UIWindow) -> [CGRect] {
    descendants(of: window).compactMap { $0 as? UICollectionViewCell }
      .filter { !$0.isHidden && $0.alpha > 0 && descendants(of: $0).contains { $0 is UITextField } }
      .map { $0.convert($0.bounds, to: window) }
      .filter { window.bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) }
      .sorted { $0.minY < $1.minY }
  }

  private static func descendants(of view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap(descendants(of:))
  }

  private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Double] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return bytes.prefix(3).map(Double.init)
  }

  private static func sourceFile(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
  }
}

private struct SheetBackgroundAgeChecker: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal {
    .init(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
  }

  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
}
