#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// A focused hosting fixture for Home's embedding contract. This is not a
/// reproduction of the user screenshot or an assertion about live feed data.
@MainActor
final class FeedHostingInsetTests: XCTestCase {
  final class Controller: UIViewController {
    let collection: UICollectionView
    var source: UICollectionViewDiffableDataSource<Int, Int>!
    let restoration = FeedViewportRestoration(anchor: nil)

    init() {
      var config = UICollectionLayoutListConfiguration(appearance: .plain)
      config.headerMode = .none
      config.footerMode = .none
      collection = UICollectionView(frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
      super.viewDidLoad()
      collection.frame = view.bounds
      collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      collection.contentInset = .zero
      collection.contentInsetAdjustmentBehavior = .automatic
      view.addSubview(collection)
      let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
        cell.contentConfiguration = UIHostingConfiguration {
          Text("A single-line feed row").font(.body).padding(.top, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }.margins(.all, 0)
      }
      source = UICollectionViewDiffableDataSource(collectionView: collection) { collection, index, id in
        collection.dequeueConfiguredReusableCell(using: registration, for: index, item: id)
      }
      var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
      snapshot.appendSections([0]); snapshot.appendItems(Array(0..<50))
      source.apply(snapshot, animatingDifferences: false)
    }
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      collection.layoutIfNeeded()
      if source != nil {
        restoration.restoreIfReady(in: collection, postCount: source.snapshot().numberOfItems,
          isLoading: false, indexPathFor: { _ in nil })
      }
    }
  }
  struct Bridge: UIViewControllerRepresentable {
    let controller: Controller
    func makeUIViewController(context: Context) -> Controller { controller }
    func updateUIViewController(_ controller: Controller, context: Context) {}
  }

  func testNarrowLargeTextEmbeddingKeepsFirstPostAtEffectiveTop() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true }
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
    let controller = Controller()
    let host = UIHostingController(rootView: NavigationStack {
      Bridge(controller: controller)
        .ignoresSafeArea()
        .navigationTitle("Timeline")
        .toolbarTitleDisplayMode(.large)
    }.dynamicTypeSize(.accessibility3))
    window.rootViewController = host
    window.isHidden = false
    for _ in 0..<8 {
      try await Task.sleep(for: .milliseconds(20))
      host.view.layoutIfNeeded()
      controller.view.layoutIfNeeded()
    }
    let collection = controller.collection
    let first = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
    XCTAssertEqual(first.frame.minY - collection.contentOffset.y - collection.adjustedContentInset.top, 0, accuracy: 1)
    XCTAssertGreaterThan(first.frame.height, 0)
  }

  func testLargeTitleFirstLayoutAndReuseHaveNoExtraCollectionOverscroll() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true }
    let controller = Controller()
    let host = UIHostingController(rootView: NavigationStack {
      Bridge(controller: controller)
        .ignoresSafeArea()
        .navigationTitle("Timeline")
        .toolbarTitleDisplayMode(.large)
    })
    window.rootViewController = host
    window.isHidden = false
    for _ in 0..<8 {
      try await Task.sleep(for: .milliseconds(20))
      host.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
    }
    let collection = controller.collection
    let first = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
    XCTAssertEqual(collection.contentOffset.y + collection.adjustedContentInset.top, 0, accuracy: 1)
    XCTAssertEqual(first.frame.minY - collection.contentOffset.y - collection.adjustedContentInset.top, 0, accuracy: 1)
    let initialHeight = first.frame.height
    collection.contentOffset.y = 500
    collection.layoutIfNeeded()
    collection.contentOffset.y = -collection.adjustedContentInset.top
    collection.layoutIfNeeded()
    let returned = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
    XCTAssertEqual(returned.frame.height, initialHeight, accuracy: 2)
    let geometry = FeedLayoutGeometry.capture(in: collection) { controller.source.itemIdentifier(for: $0).map { String($0) } }
    XCTAssertEqual(geometry.contentInset, .zero)
    XCTAssertFalse(geometry.isRefreshing)
  }
}
#endif
