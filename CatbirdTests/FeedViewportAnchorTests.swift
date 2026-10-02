#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

@MainActor
final class FeedViewportAnchorTests: XCTestCase {
  enum Row: Hashable {
    case header, trending, post(String)
    var postID: String? { if case .post(let id) = self { return id }; return nil }
  }

  @MainActor
  final class Fixture {
    let window: UIWindow
    let controller = UIViewController()
    let collection: UICollectionView
    var source: UICollectionViewDiffableDataSource<Int, Row>!

    init(topInset: CGFloat = 100) throws {
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      let layout = UICollectionViewFlowLayout()
      layout.itemSize = CGSize(width: 380, height: 100)
      layout.minimumLineSpacing = 0
      layout.minimumInteritemSpacing = 0
      collection = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
      collection.contentInsetAdjustmentBehavior = .never
      collection.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 20, right: 0)
      collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
      controller.view.addSubview(collection)
      window.rootViewController = controller
      window.isHidden = false
      source = UICollectionViewDiffableDataSource(collectionView: collection) { collection, index, _ in
        collection.dequeueReusableCell(withReuseIdentifier: "row", for: index)
      }
    }

    func apply(_ rows: [Row]) async {
      var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
      snapshot.appendSections([0])
      snapshot.appendItems(rows)
      await withCheckedContinuation { continuation in
        source.apply(snapshot, animatingDifferences: false) { continuation.resume() }
      }
      collection.layoutIfNeeded()
    }

    var posts: Int { source.snapshot().itemIdentifiers.filter { $0.postID != nil }.count }
    func index(_ id: String) -> IndexPath? { source.indexPath(for: .post(id)) }
    func capture() -> FeedViewportAnchor? {
      FeedViewportAnchor.capture(in: collection) { self.source.itemIdentifier(for: $0)?.postID }
    }
    func viewportY(_ id: String) throws -> CGFloat {
      let index = try XCTUnwrap(index(id))
      let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: index)).frame
      return frame.minY - collection.contentOffset.y - collection.adjustedContentInset.top
    }
  }

  var rows: [Row] { (0..<30).map { .post("p\($0)") } }

  func testHeaderIsSkippedWhenCapturingFirstVisiblePost() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    await fixture.apply([.header] + rows)
    fixture.collection.contentOffset.y = -fixture.collection.adjustedContentInset.top
    fixture.collection.layoutIfNeeded()
    let anchor = try XCTUnwrap(fixture.capture())
    XCTAssertEqual(anchor.postID, "p0")
    XCTAssertTrue(anchor.isAtTop)
    XCTAssertEqual(anchor.viewportY, try fixture.viewportY("p0"), accuracy: 1)
  }

  func testTrendingRowIsSkippedAndRemovedWithoutChangingReadingIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    var withTrending = rows
    withTrending.insert(.trending, at: 6)
    await fixture.apply(withTrending)
    fixture.collection.contentOffset.y = 550
    fixture.collection.layoutIfNeeded()
    let anchor = try XCTUnwrap(fixture.capture())
    XCTAssertEqual(anchor.postID, "p6")
    await fixture.apply(rows)
    anchor.restore(in: fixture.collection, indexPath: try XCTUnwrap(fixture.index(anchor.postID)))
    XCTAssertEqual(try fixture.viewportY(anchor.postID), anchor.viewportY, accuracy: 1)
  }

  func testNewControllerRestoresStableIdentityAcrossHeaderAndInsetChanges() async throws {
    let old = try Fixture(topInset: 156)
    defer { old.window.isHidden = true }
    var original = [.header] + rows
    original.insert(.trending, at: 7)
    await old.apply(original)
    old.collection.contentOffset.y = 750
    old.collection.layoutIfNeeded()
    let anchor = try XCTUnwrap(old.capture())

    // A distinct view/controller/data source exercises the recreation boundary.
    let fresh = try Fixture(topInset: 64)
    defer { fresh.window.isHidden = true }
    await fresh.apply(rows)
    let restoration = FeedViewportRestoration(anchor: anchor)
    XCTAssertTrue(restoration.restoreIfReady(in: fresh.collection, postCount: fresh.posts,
      isLoading: false, indexPathFor: fresh.index))
    XCTAssertEqual(try fresh.viewportY(anchor.postID), anchor.viewportY, accuracy: 1)
    XCTAssertFalse(restoration.isPending)
    let settled = fresh.collection.contentOffset
    XCTAssertFalse(restoration.restoreIfReady(in: fresh.collection, postCount: fresh.posts,
      isLoading: false, indexPathFor: fresh.index))
    XCTAssertEqual(fresh.collection.contentOffset, settled)
  }

  func testTopStateDoesNotTurnIntoOverscrollAfterLargeTitleInsetChanges() async throws {
    let fixture = try Fixture(topInset: 156)
    defer { fixture.window.isHidden = true }
    await fixture.apply(rows)
    fixture.collection.contentOffset.y = -156
    fixture.collection.layoutIfNeeded()
    let anchor = try XCTUnwrap(fixture.capture())
    fixture.collection.contentInset.top = 64
    let restoration = FeedViewportRestoration(anchor: anchor)
    restoration.restoreIfReady(in: fixture.collection, postCount: fixture.posts,
      isLoading: false, indexPathFor: fixture.index)
    XCTAssertEqual(fixture.collection.contentOffset.y, -64, accuracy: 1)
  }

  func testMissingAnchorWaitsForLoadingThenFallsBackToTop() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    await fixture.apply(rows)
    fixture.collection.contentOffset.y = 600
    let restoration = FeedViewportRestoration(anchor:
      FeedViewportAnchor(postID: "not-loaded", viewportY: -20, isAtTop: false))
    XCTAssertFalse(restoration.restoreIfReady(in: fixture.collection, postCount: fixture.posts,
      isLoading: true, indexPathFor: fixture.index))
    XCTAssertTrue(restoration.isPending)
    XCTAssertTrue(restoration.restoreIfReady(in: fixture.collection, postCount: fixture.posts,
      isLoading: false, indexPathFor: fixture.index))
    XCTAssertEqual(fixture.collection.contentOffset.y, -100, accuracy: 1)
  }

  func testUserDragCancelsPendingRestoreAndResetUsesNewFeedAnchor() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    await fixture.apply(rows)
    let restoration = FeedViewportRestoration(anchor:
      FeedViewportAnchor(postID: "p9", viewportY: -15, isAtTop: false))
    // This is the same cancellation boundary called by scrollViewWillBeginDragging.
    restoration.cancel()
    fixture.collection.contentOffset.y = 600
    XCTAssertFalse(restoration.restoreIfReady(in: fixture.collection, postCount: fixture.posts,
      isLoading: false, indexPathFor: fixture.index))
    XCTAssertEqual(fixture.collection.contentOffset.y, 600, accuracy: 1)
    restoration.reset(to: FeedViewportAnchor(postID: "p15", viewportY: -30, isAtTop: false))
    // A completion from the previous feed cannot consume the new request.
    XCTAssertFalse(restoration.restoreIfReady(in: fixture.collection, postCount: fixture.posts,
      isLoading: false, snapshotGeneration: 0, indexPathFor: fixture.index))
    XCTAssertEqual(fixture.collection.contentOffset.y, 600, accuracy: 1)
    XCTAssertTrue(restoration.restoreIfReady(in: fixture.collection, postCount: fixture.posts,
      isLoading: false, snapshotGeneration: restoration.generation, indexPathFor: fixture.index))
    XCTAssertEqual(try fixture.viewportY("p15"), -30, accuracy: 1)
  }
}
#endif
