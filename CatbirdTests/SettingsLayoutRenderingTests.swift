#if os(iOS) && DEBUG
import Petrel
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Hosted production forms, not a resized phone scene or authenticated-account test.
/// Optional SETTINGS_LAYOUT_SNAPSHOT_DIR exports the same images kept in xcresult.
/// Run the two methods separately after setting the simulator to Large and
/// Accessibility Extra Large respectively, so production UIFontMetrics uses the
/// same system category as the hosted hierarchy. Each method needs a fresh host.
@MainActor
final class SettingsLayoutRenderingTests: XCTestCase {
  private struct Viewport {
    let name: String
    let size: CGSize
  }

  private let viewports = [
    Viewport(name: "narrow", size: CGSize(width: 320, height: 700)),
    Viewport(name: "wide", size: CGSize(width: 744, height: 600)),
    Viewport(name: "short", size: CGSize(width: 640, height: 320)),
    Viewport(name: "tall", size: CGSize(width: 390, height: 960)),
    Viewport(name: "square", size: CGSize(width: 600, height: 600))
  ]

  func testSettingsFormsFitReceivingContainersAndReachTheirLastRow() async throws {
    let fixture = try await Fixture()
    defer { fixture.restoreDefaults() }
    for screen in [Screen.root, .appearance, .accessibility, .textReadability, .language, .content] {
      for viewport in viewports {
        try await inspect(screen: screen, viewport: viewport, fixture: fixture)
      }
    }
    XCTAssertEqual(fixture.tipClient.purchaseAttempts, 0)
  }

  func testAboutCatalogAndRetryFitLargeTextWithAsymmetricSafeAreas() async throws {
    let fixture = try await Fixture()
    defer { fixture.restoreDefaults() }
    await fixture.supportStore.loadProducts()
    XCTAssertEqual(Set(fixture.supportStore.products.map(\.id)), SupportTipStore.productIDs)
    for viewport in viewports {
      try await inspect(screen: .about, viewport: viewport, fixture: fixture, largeText: true)
    }
    fixture.tipClient.unavailable = true
    await fixture.supportStore.loadProducts(forceReload: true)
    XCTAssertEqual(fixture.supportStore.loadState, .unavailable)
    try await inspect(screen: .aboutUnavailable,
      viewport: Viewport(name: "narrow-short", size: CGSize(width: 320, height: 480)),
      fixture: fixture, largeText: true)
    XCTAssertEqual(fixture.tipClient.purchaseAttempts, 0)
  }

  func testReadabilityAndLanguagesFitFullSystemAccessibilityRange() async throws {
    let fixture = try await Fixture()
    defer { fixture.restoreDefaults() }
    fixture.appState.appSettings.maxDynamicTypeSize = AppTextSizeLimit.fullSystemRange
    XCTAssertTrue(fixture.appState.appSettings.persistPendingChanges())
    fixture.appState.fontManager.maxDynamicTypeSize = AppTextSizeLimit.fullSystemRange
    for screen in [Screen.textReadability, .language] {
      for viewport in viewports {
        try await inspect(screen: screen, viewport: viewport, fixture: fixture,
          largeText: true, systemCategory: .accessibilityExtraExtraExtraLarge)
      }
    }
  }

  private enum Screen: String {
    case root, appearance, accessibility, textReadability, language, content, about, aboutUnavailable
  }

  @ViewBuilder
  private func screen(_ screen: Screen, fixture: Fixture) -> some View {
    switch screen {
    case .root: SettingsView()
    case .appearance: NavigationStack { AppearanceSettingsView() }
    case .accessibility: NavigationStack { AccessibilitySettingsView() }
    case .textReadability: NavigationStack { TextReadabilitySettingsView() }
    case .language: NavigationStack { LanguageSettingsView() }
    case .content: NavigationStack { ContentMediaSettingsView() }
    case .about, .aboutUnavailable:
      NavigationStack { AboutSettingsView(supportStore: fixture.supportStore) }
    }
  }

  private func inspect(screen: Screen, viewport: Viewport, fixture: Fixture,
                       largeText: Bool = false, systemCategory: UIContentSizeCategory? = nil) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let category: UIContentSizeCategory = systemCategory ?? (largeText ? .accessibilityExtraLarge : .large)
    guard UIApplication.shared.preferredContentSizeCategory == category,
      fixture.appState.fontManager.currentContentSizeCategory.uiContentSizeCategory == category else {
      XCTFail("Set the simulator to \(category.rawValue) and launch a fresh test host; a host trait override alone does not qualify production font scaling")
      return
    }
    let safeArea = largeText ? UIEdgeInsets(top: 13, left: 31, bottom: 47, right: 7) : .zero
    let content = self.screen(screen, fixture: fixture)
      .environment(fixture.appState)
      .environment(\.fontManager, fixture.appState.fontManager)
      .environment(\.dynamicTypeSize, category == .accessibilityExtraExtraExtraLarge ? .accessibility5 : (largeText ? .accessibility3 : .large))
      .environment(\.colorScheme, largeText ? .dark : .light)
      .modelContainer(fixture.container)
    let host = UIHostingController(rootView: content)
    host.overrideUserInterfaceStyle = largeText ? .dark : .light
    host.traitOverrides.preferredContentSizeCategory = category
    host.additionalSafeAreaInsets = safeArea
    let parent = FixedViewportController(child: host, size: viewport.size)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = parent
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    await settle(host: host, parent: parent)

    let label = "\(screen.rawValue)-\(viewport.name)-\(largeText ? "large-dark" : "normal-light")"
    // A UIWindow can silently retain device dimensions. Assert the receiving child,
    // which is deliberately sized by its container instead of by UIWindow.frame.
    XCTAssertEqual(host.view.bounds.width, viewport.size.width, accuracy: 0.5, label)
    XCTAssertEqual(host.view.bounds.height, viewport.size.height, accuracy: 0.5, label)
    XCTAssertEqual(host.traitCollection.preferredContentSizeCategory, category, label)
    XCTAssertGreaterThanOrEqual(host.view.safeAreaInsets.top, safeArea.top, label)
    XCTAssertGreaterThanOrEqual(host.view.safeAreaInsets.left, safeArea.left, label)
    XCTAssertGreaterThanOrEqual(host.view.safeAreaInsets.right, safeArea.right, label)
    XCTAssertGreaterThanOrEqual(host.view.safeAreaInsets.bottom, safeArea.bottom, label)

    let collection = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UICollectionView }
      .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }), label)
    XCTAssertGreaterThan(collection.bounds.width, 0, label)
    XCTAssertGreaterThan(collection.bounds.height, 0, label)
    XCTAssertLessThanOrEqual(collection.contentSize.width, collection.bounds.width + 1, label)
    assertVisibleRowsWithinHorizontalBounds(collection, label: label)
    try attach(host.view, named: "\(label)-top")

    let lastSection = try XCTUnwrap((0..<collection.numberOfSections).last {
      collection.numberOfItems(inSection: $0) > 0
    }, label)
    let last = IndexPath(item: collection.numberOfItems(inSection: lastSection) - 1, section: lastSection)
    collection.scrollToItem(at: last, at: .bottom, animated: false)
    await settle(host: host, parent: parent)
    XCTAssertTrue(collection.indexPathsForVisibleItems.contains(last), "Last row is not reachable: \(label)")
    let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: last), label)
    XCTAssertGreaterThan(attributes.frame.intersection(collection.bounds).height, 0, label)
    XCTAssertLessThanOrEqual(attributes.frame.maxY,
      collection.bounds.maxY - collection.adjustedContentInset.bottom + 1, label)
    assertVisibleRowsWithinHorizontalBounds(collection, label: label)
    try attach(host.view, named: "\(label)-bottom")

    let globalCategory = UIApplication.shared.preferredContentSizeCategory.rawValue
    let effectiveCategory = host.traitCollection.preferredContentSizeCategory.rawValue
    let receipt = """
    \(label)
    Requested receiving bounds: \(viewport.size)
    Actual receiving bounds: \(host.view.bounds)
    Scene window bounds: \(window.bounds)
    Snapshot: drawHierarchy of the whole receiving child at scale 1; wide/tall child may extend beyond the scene window.
    Actual safe-area insets: \(host.view.safeAreaInsets)
    Form bounds: \(collection.bounds); content size: \(collection.contentSize)
    Form adjusted content insets: \(collection.adjustedContentInset)
    Last row: \(last); rendered frame: \(attributes.frame)
    UIKit host category: \(effectiveCategory)
    UIApplication category: \(globalCategory)
    Category evidence: system, FontManager cache category, and host must match before rendering.
    Evidence boundary: production hosted forms with fixture account/catalog; no scene-resize continuity, authenticated behavior or purchase claim.
    """
    let attachment = XCTAttachment(string: receipt)
    attachment.name = "\(label)-geometry"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("SETTINGS_LAYOUT_RECEIPT \(receipt)")

    if !largeText && screen == .accessibility && ["narrow", "short"].contains(viewport.name) {
      try await captureWholeFormSweep(collection, host: host, parent: parent, label: label)
    }
    if !largeText && screen == .appearance {
      try await captureContentEnd(collection, host: host, parent: parent, label: label)
    }
  }

  private func assertVisibleRowsWithinHorizontalBounds(_ collection: UICollectionView, label: String) {
    for cell in collection.visibleCells where cell.frame.intersects(collection.bounds) {
      XCTAssertGreaterThan(cell.bounds.height, 0, label)
      XCTAssertGreaterThanOrEqual(cell.frame.minX, collection.bounds.minX - 1, label)
      XCTAssertLessThanOrEqual(cell.frame.maxX, collection.bounds.maxX + 1, label)
    }
  }

  private func settle<Content: View>(host: UIHostingController<Content>, parent: UIViewController) async {
    for _ in 0..<8 {
      parent.view.setNeedsLayout()
      parent.view.layoutIfNeeded()
      host.traitCollection.performAsCurrent { host.view.layoutIfNeeded() }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  private func descendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  private func attach(_ view: UIView, named name: String) throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    var rendered = false
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
      rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    XCTAssertTrue(rendered, "The hosted hierarchy did not finish rendering: \(name)")
    XCTAssertEqual(image.size, view.bounds.size)
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let directory = ProcessInfo.processInfo.environment["SETTINGS_LAYOUT_SNAPSHOT_DIR"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try image.pngData()?.write(to: url.appendingPathComponent(name).appendingPathExtension("png"))
    }
  }

  /// UIViewController containment keeps the test's actual receiving geometry stable.
  @MainActor
  private final class FixedViewportController: UIViewController {
    let child: UIViewController
    let size: CGSize
    init(child: UIViewController, size: CGSize) {
      self.child = child
      self.size = size
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
      super.viewDidLoad()
      addChild(child)
      view.addSubview(child.view)
      child.didMove(toParent: self)
    }
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      child.view.frame = CGRect(origin: .zero, size: size)
    }
  }

  @MainActor
  private final class Fixture {
    let container: ModelContainer
    let appState: AppState
    let tipClient = TipClient()
    let supportStore: SupportTipStore
    private let savedDefaults: [(UserDefaults, String, Any?)]

    init() async throws {
      // Root Settings fetches its profile from the shared authentication service.
      // Refuse an authenticated host instead of touching that account or its network.
      guard AppStateManager.shared.authentication.client == nil else {
        throw XCTSkip("Run this fixture suite on the dedicated unauthenticated Settings simulator")
      }
      let did = "did:plc:layoutfixture\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
      let keys = ["theme", "darkThemeMode", "accentColor", "fontStyle", "fontSize", "lineSpacing",
        "letterSpacing", "dynamicTypeEnabled", "maxDynamicTypeSize", "useWebViewEmbeds"]
        + ExternalMediaProvider.allCases.map { "externalMediaConsent.\($0.rawValue)" }
      let standardKeys = keys + keys.map { AppSettingsModel.scopedKey($0, accountDID: did) }
        + ["lastActiveSettingsAccountDID"]
      self.savedDefaults = standardKeys.map { (UserDefaults.standard, $0, UserDefaults.standard.object(forKey: $0)) }
        + ["theme", "darkThemeMode"].map {
          (AppSettingsModel.sharedDefaults(), $0, AppSettingsModel.sharedDefaults().object(forKey: $0))
        }
      container = try ModelContainer(for: AppSettingsModel.self, Preferences.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
      let settings = AppSettingsModel(accountDID: did)
      settings.maxDynamicTypeSize = "accessibility5"
      container.mainContext.insert(settings)
      try container.mainContext.save()
      let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
      appState = AppState(userDID: did, client: client, regulatoryChecker: NoAgePrompt())
      // Leave PreferencesManager's client unset so server controls fail locally.
      appState.appSettings.initialize(with: container.mainContext, accountDID: did)
      appState.fontManager.fontStyle = "system"
      appState.fontManager.fontSize = "default"
      appState.fontManager.dynamicTypeEnabled = true
      appState.fontManager.maxDynamicTypeSize = "accessibility5"
      supportStore = SupportTipStore(client: tipClient)
    }

    func restoreDefaults() {
      appState.cleanup()
      // Restore only the documented mirroring keys touched by AppSettings.initialize.
      // Fixture-scoped keys had no previous value; no account or draft is removed.
      for (defaults, key, value) in savedDefaults {
        if let value {
          defaults.set(value, forKey: key)
        } else {
          defaults.removeObject(forKey: key)
        }
      }
    }
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @MainActor
  private final class TipClient: SupportTipClient {
    var unavailable = false
    private(set) var purchaseAttempts = 0
    func products(for identifiers: Set<String>) async throws -> [SupportTipProduct] {
      guard !unavailable else { return [] }
      return [
        SupportTipProduct(id: "blue.catbird.support.onetime.small", displayName: "Small Support", displayPrice: "$4.99", price: 4.99),
        SupportTipProduct(id: "blue.catbird.support.onetime.medium", displayName: "Medium Support", displayPrice: "$9.99", price: 9.99),
        SupportTipProduct(id: "blue.catbird.support.onetime.large", displayName: "Large Support", displayPrice: "$19.99", price: 19.99),
        SupportTipProduct(id: "blue.catbird.support.onetime.extralarge", displayName: "Extra Large Support", displayPrice: "$49.99", price: 49.99)
      ].filter { identifiers.contains($0.id) }
    }
    func purchase(productID: String) async throws -> SupportTipPurchaseResult {
      purchaseAttempts += 1
      XCTFail("Layout tests must never initiate a purchase")
      return .cancelled
    }
    func transactionUpdates() -> AsyncStream<SupportTipVerification> { AsyncStream { $0.finish() } }
    func unfinishedTransactions() -> AsyncStream<SupportTipVerification> { AsyncStream { $0.finish() } }
    func storefrontUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  }
}

private extension SettingsLayoutRenderingTests {
  @MainActor
  struct ScrollCaptureGeometry {
    let offset: CGPoint
    let contentSize: CGSize
    let bounds: CGRect
    let insets: UIEdgeInsets

    init(_ collection: UICollectionView) {
      offset = collection.contentOffset
      contentSize = collection.contentSize
      bounds = collection.bounds
      insets = collection.adjustedContentInset
    }

    var topOffset: CGFloat { -insets.top }
    var endOffset: CGFloat { max(topOffset, contentSize.height - bounds.height + insets.bottom) }
    var usefulHeight: CGFloat { bounds.height - insets.top - insets.bottom }
    var visibleTop: CGFloat { offset.y + insets.top }
    var visibleBottom: CGFloat { offset.y + bounds.height - insets.bottom }
    var isAtEnd: Bool { abs(offset.y - endOffset) <= 1 }
    var description: String {
      """
      Content offset: \(offset); content size: \(contentSize)
      Collection bounds: \(bounds); adjusted content insets: \(insets)
      Legal top: \(topOffset); actual content end: \(endOffset); useful viewport height: \(usefulHeight)
      Visible content range: \(visibleTop)...\(visibleBottom)
      """
    }
  }

  func captureWholeFormSweep<Content: View>(_ collection: UICollectionView,
                                            host: UIHostingController<Content>, parent: UIViewController, label: String) async throws {
    let initial = ScrollCaptureGeometry(collection)
    collection.setContentOffset(CGPoint(x: initial.offset.x, y: initial.topOffset), animated: false)
    await settle(host: host, parent: parent)
    var reachedEnd = false
    var previousTop: CGFloat?
    var previousBottom: CGFloat?

    for index in 0..<24 {
      let current = ScrollCaptureGeometry(collection)
      guard current.usefulHeight > 0 else {
        XCTFail("The Form has no useful viewport for the capture sweep: \(label)")
        return
      }
      if index == 0 {
        XCTAssertEqual(current.offset.y, current.topOffset, accuracy: 1, "Sweep must start at the actual top: \(label)")
      }
      let name = "\(label)-sweep-\(String(format: "%02d", index))"
      let captured = try attachScrollPosition(collection, view: host.view, named: name)
      guard captured.usefulHeight > 0 else {
        XCTFail("The captured Form has no useful viewport: \(name)")
        return
      }
      if let previousTop, let previousBottom {
        XCTAssertLessThanOrEqual(max(previousTop, captured.visibleTop), min(previousBottom, captured.visibleBottom) + 1,
          "Sweep captures must overlap without a gap in either direction: \(name)")
      }
      previousTop = captured.visibleTop
      previousBottom = captured.visibleBottom
      if captured.isAtEnd {
        reachedEnd = true
        break
      }
      if index < 23 {
        // Self-sizing rows can change content size while settling. Advance from
        // the measured offset and recompute the end and useful height each time.
        let next = min(captured.endOffset, captured.offset.y + captured.usefulHeight / 2)
        collection.setContentOffset(CGPoint(x: captured.offset.x, y: next), animated: false)
        await settle(host: host, parent: parent)
      }
    }
    XCTAssertTrue(reachedEnd, "The bounded overlapping sweep must reach the actual content end: \(label)")
    let final = ScrollCaptureGeometry(collection)
    XCTAssertEqual(final.offset.y, final.endOffset, accuracy: 1, "Sweep content end: \(label)")
  }

  func captureContentEnd<Content: View>(_ collection: UICollectionView,
                                        host: UIHostingController<Content>, parent: UIViewController, label: String) async throws {
    for _ in 0..<8 {
      let current = ScrollCaptureGeometry(collection)
      collection.setContentOffset(CGPoint(x: current.offset.x, y: current.endOffset), animated: false)
      await settle(host: host, parent: parent)
      if ScrollCaptureGeometry(collection).isAtEnd { break }
    }
    let settled = ScrollCaptureGeometry(collection)
    XCTAssertEqual(settled.offset.y, settled.endOffset, accuracy: 1, "Appearance content end after settling: \(label)")
    let captured = try attachScrollPosition(collection, view: host.view, named: "\(label)-content-end")
    XCTAssertEqual(captured.offset.y, captured.endOffset, accuracy: 1, "Appearance content end after capture: \(label)")
  }

  func attachScrollPosition(_ collection: UICollectionView, view: UIView,
                            named name: String) throws -> ScrollCaptureGeometry {
    let before = ScrollCaptureGeometry(collection)
    try attach(view, named: name)
    let after = ScrollCaptureGeometry(collection)
    XCTAssertEqual(before.visibleTop, after.visibleTop, accuracy: 1, "Capture visible top must remain stable: \(name)")
    XCTAssertEqual(before.visibleBottom, after.visibleBottom, accuracy: 1, "Capture visible bottom must remain stable: \(name)")
    let receipt = """
    \(name)
    Before capture:
    \(before.description)
    After capture:
    \(after.description)
    Evidence boundary: additional hosted Form pixels only. Review the image to identify complete text glyphs; no accessibility target or production behavior claim.
    """
    let attachment = XCTAttachment(string: receipt)
    attachment.name = "\(name)-scroll-geometry"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("SETTINGS_LAYOUT_SCROLL_RECEIPT \(receipt)")
    return after
  }
}
#endif
