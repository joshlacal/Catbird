#if os(iOS) && DEBUG
import Petrel
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Hosted production forms, not a resized phone scene or authenticated-account test.
/// Optional SETTINGS_LAYOUT_SNAPSHOT_DIR exports the same images kept in xcresult.
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
    for screen in [Screen.root, .appearance, .accessibility, .content] {
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

  private enum Screen: String {
    case root, appearance, accessibility, content, about, aboutUnavailable
  }

  @ViewBuilder
  private func screen(_ screen: Screen, fixture: Fixture) -> some View {
    switch screen {
    case .root: SettingsView()
    case .appearance: NavigationStack { AppearanceSettingsView() }
    case .accessibility: NavigationStack { AccessibilitySettingsView() }
    case .content: NavigationStack { ContentMediaSettingsView() }
    case .about, .aboutUnavailable:
      NavigationStack { AboutSettingsView(supportStore: fixture.supportStore) }
    }
  }

  private func inspect(screen: Screen, viewport: Viewport, fixture: Fixture,
                       largeText: Bool = false) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let category: UIContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
    let safeArea = largeText ? UIEdgeInsets(top: 13, left: 31, bottom: 47, right: 7) : .zero
    let content = self.screen(screen, fixture: fixture)
      .environment(fixture.appState)
      .environment(\.fontManager, fixture.appState.fontManager)
      .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
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
    Category evidence: \(globalCategory == effectiveCategory ? "system preference and host match" : "host trait override only; system preference differs")
    Evidence boundary: production hosted forms with fixture account/catalog; no scene-resize continuity, authenticated behavior or purchase claim.
    """
    let attachment = XCTAttachment(string: receipt)
    attachment.name = "\(label)-geometry"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("SETTINGS_LAYOUT_RECEIPT \(receipt)")
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
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
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
#endif
