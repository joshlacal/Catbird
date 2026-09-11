#if os(iOS)
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Exercises actual UIHostingConfiguration invalidation, not only geometry arithmetic.
@MainActor
final class ChatAnchoredLayoutTests: XCTestCase {
  @Observable
  final class Rows {
    var heights = Dictionary(uniqueKeysWithValues: (0..<30).map { ($0, CGFloat(80)) })
    @ObservationIgnored var renderedHeights: [Int: CGFloat] = [:]
    @ObservationIgnored var renderedEmbedHeights: [Int: CGFloat] = [:]
  }

  /// Keep the observable read inside a View.body. Reading it in the hosting
  /// configuration builder only constructs a value once and never subscribes.
  struct DelayedEmbedRow: View {
    let rows: Rows
    let id: Int

    var body: some View {
      VStack {
        Text("Message \(id): shared post resolves asynchronously").font(.body)
        Color.clear.frame(height: rows.heights[id] ?? 80)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rows.renderedEmbedHeights[id] = $0 }
      }
      // Match the real message's vertically self-sizing text instead of allowing
      // an estimated UIKit height to compress the label during baseline capture.
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rows.renderedHeights[id] = $0 }
    }
  }

  @MainActor
  final class Fixture {
    let rows = Rows()
    let window: UIWindow
    let collection: UICollectionView
    var source: UICollectionViewDiffableDataSource<Int, Int>!

    init(count: Int = 30) throws {
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      collection = ChatTranscriptCollectionView(frame: window.bounds, collectionViewLayout: ChatAnchoredLayout())
      collection.contentInset.bottom = 100
      collection.contentInsetAdjustmentBehavior = .never
      let controller = UIViewController()
      controller.view.addSubview(collection)
      window.rootViewController = controller
      window.isHidden = false
      let registration = UICollectionView.CellRegistration<ChatTranscriptCell, Int> { [rows] cell, _, id in
        cell.contentConfiguration = UIHostingConfiguration {
          ChatTranscriptContent(cell: cell) { DelayedEmbedRow(rows: rows, id: id) }
        }.margins(.all, 0)
      }
      source = UICollectionViewDiffableDataSource(collectionView: collection) { collection, index, id in
        collection.dequeueConfiguredReusableCell(using: registration, for: index, item: id)
      }
      var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
      snapshot.appendSections([0])
      snapshot.appendItems(Array(0..<count))
      source.apply(snapshot, animatingDifferences: false)
      collection.layoutIfNeeded()
    }

    var bottom: CGFloat { max(0, collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom) }
    func pinBottom() {
      (collection.collectionViewLayout as? ChatAnchoredLayout)?.preservesSelfSizingAnchor = false
      for _ in 0..<3 {
        collection.contentOffset.y = bottom
        collection.layoutIfNeeded()
      }
      (collection.collectionViewLayout as? ChatAnchoredLayout)?.preservesSelfSizingAnchor = true
    }
    func anchor() -> (Int, CGFloat) {
      let index = collection.indexPathsForVisibleItems.sorted().first {
        (collection.layoutAttributesForItem(at: $0)?.frame.maxY ?? 0) > collection.contentOffset.y
      }!
      return (index.item, collection.layoutAttributesForItem(at: index)!.frame.minY - collection.contentOffset.y)
    }
    func viewportY(_ item: Int) -> CGFloat {
      collection.layoutAttributesForItem(at: IndexPath(item: item, section: 0))!.frame.minY - collection.contentOffset.y
    }
    func height(_ id: Int) throws -> CGFloat {
      let index = try XCTUnwrap(source.indexPath(for: id))
      return try XCTUnwrap(collection.layoutAttributesForItem(at: index)).frame.height
    }

    func baselineHeight(_ id: Int) async throws -> CGFloat {
      try await waitForMeasuredChange(id) { height in
        guard let index = self.source.indexPath(for: id),
          self.collection.cellForItem(at: index) != nil,
          let rendered = self.rows.renderedHeights[id],
          let embed = self.rows.renderedEmbedHeights[id] else { return false }
        return abs(rendered - height) <= 2 && abs(embed - 80) <= 1
      }
      return try height(id)
    }

    func waitForHeight(_ id: Int, expected: CGFloat, file: StaticString = #filePath, line: UInt = #line) async throws {
      try await waitForMeasuredChange(id, file: file, line: line) { abs($0 - expected) <= 2 }
      XCTAssertEqual(try height(id), expected, accuracy: 2, file: file, line: line)
      XCTAssertEqual(try XCTUnwrap(rows.renderedEmbedHeights[id]), try XCTUnwrap(rows.heights[id]), accuracy: 1, file: file, line: line)
      let index = try XCTUnwrap(source.indexPath(for: id))
      let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: index))
      XCTAssertEqual(attributes.size.width, collection.bounds.width - collection.adjustedContentInset.left - collection.adjustedContentInset.right, accuracy: 1, file: file, line: line)
    }

    func waitForMeasuredChange(
      _ id: Int, file: StaticString = #filePath, line: UInt = #line,
      matches: (CGFloat) -> Bool
    ) async throws {
      for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(20))
        collection.layoutIfNeeded()
        if matches(try height(id)) { return }
      }
      let index = source.indexPath(for: id)
      let cell = index.flatMap { collection.cellForItem(at: $0) as? ChatTranscriptCell }
      print("CHAT_SAFE_AREA cell=\(String(describing: cell?.safeAreaInsets)) content=\(String(describing: cell?.contentView.safeAreaInsets)) hosted=\(String(describing: cell?.contentView.subviews.first?.safeAreaInsets))")
      let previousPreferred = cell?.lastPreferredSize
      let fitting = index.flatMap { collection.layoutAttributesForItem(at: $0) }.map {
        cell?.preferredLayoutAttributesFitting($0).size
      }
      print("CHAT_BASELINE id=\(id) cellFrame=\(String(describing: cell?.frame)) contentBounds=\(String(describing: cell?.contentView.bounds)) lastPreferred=\(String(describing: previousPreferred)) freshFitting=\(String(describing: fitting))")
      XCTContext.runActivity(named: "Chat baseline sizing failure") { activity in
        let renderer = UIGraphicsImageRenderer(bounds: collection.bounds)
        let image = renderer.image { _ in collection.drawHierarchy(in: collection.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.lifetime = .keepAlways
        activity.add(attachment)
      }
      XCTFail("Hosting cell did not resize: id=\(id), measured=\(try height(id)), model=\(rows.heights[id] ?? -1), rendered=\(rows.renderedHeights[id] ?? -1), embed=\(rows.renderedEmbedHeights[id] ?? -1), category=\(collection.traitCollection.preferredContentSizeCategory.rawValue), content=\(collection.contentSize), offset=\(collection.contentOffset)", file: file, line: line)
      throw NSError(domain: "ChatAnchoredLayoutTests.UnchangedHostingCell", code: 1)
    }

    func settle() async throws {
      try await Task.sleep(for: .milliseconds(150))
      collection.layoutIfNeeded()
    }
  }

  func testOutOfOrderVisibleEmbedsKeepReadingAnchor() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    fixture.collection.contentOffset.y = 900
    try await fixture.settle()
    let (item, y) = fixture.anchor()
    let initialEmbedHeight = try await fixture.baselineHeight(item + 2)
    let initialAnchorHeight = try await fixture.baselineHeight(item)
    fixture.rows.heights[item + 2] = 340
    try await fixture.waitForHeight(item + 2, expected: initialEmbedHeight + 260)
    fixture.rows.heights[item] = 280
    try await fixture.waitForHeight(item, expected: initialAnchorHeight + 200)
    XCTAssertEqual(fixture.viewportY(item), y, accuracy: 2)
    fixture.rows.heights[item + 2] = 40 // Error state shrinks after another post resolves.
    try await fixture.waitForHeight(item + 2, expected: initialEmbedHeight - 40)
    XCTAssertEqual(fixture.viewportY(item), y, accuracy: 2)
  }

  func testSimultaneousBottomEmbedsRemainAtBottom() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    fixture.pinBottom()
    try await fixture.settle()
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2, "Fixture must start bottom-locked")
    let height28 = try await fixture.baselineHeight(28)
    let height29 = try await fixture.baselineHeight(29)
    fixture.rows.heights[28] = 300
    fixture.rows.heights[29] = 340
    try await fixture.waitForHeight(28, expected: height28 + 220)
    try await fixture.waitForHeight(29, expected: height29 + 260)
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
    fixture.rows.heights[29] = 40
    try await fixture.waitForHeight(29, expected: height29 - 40)
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
  }

  func testSimultaneousGrowthCrossesShortTranscriptBoundary() async throws {
    let fixture = try Fixture(count: 3)
    defer { fixture.window.isHidden = true }
    try await fixture.settle()
    XCTAssertEqual(fixture.bottom, 0, accuracy: 2)
    let height1 = try await fixture.baselineHeight(1)
    let height2 = try await fixture.baselineHeight(2)
    fixture.rows.heights[1] = 360
    fixture.rows.heights[2] = 400
    try await fixture.waitForHeight(1, expected: height1 + 280)
    try await fixture.waitForHeight(2, expected: height2 + 320)
    XCTAssertGreaterThan(fixture.bottom, 0)
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
  }

  func testDelayedResizeDuringHistoryPrependRestoresIdentityOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    fixture.collection.contentOffset.y = 900
    try await fixture.settle()
    let anchor = try XCTUnwrap(ChatVisibleItemAnchor<Int>.capture(
      in: fixture.collection,
      itemAt: { fixture.source.itemIdentifier(for: $0) }, include: { _ in true }
    ))
    // A post starts resolving in the same turn as history arrives. This uses the
    // controller's exact capture/apply/layout/restore path, not duplicate math.
    let initialEmbedHeight = try await fixture.baselineHeight(anchor.item + 1)
    let initialAnchorHeight = try await fixture.baselineHeight(anchor.item)
    fixture.rows.heights[anchor.item + 1] = 320
    var snapshot = fixture.source.snapshot()
    snapshot.insertItems([-3, -2, -1], beforeItem: 0)
    UIView.performWithoutAnimation {
      fixture.source.apply(snapshot, animatingDifferences: false)
      fixture.collection.layoutIfNeeded()
      anchor.restore(in: fixture.collection, indexPathFor: { fixture.source.indexPath(for: $0) })
    }
    try await fixture.waitForHeight(anchor.item + 1, expected: initialEmbedHeight + 240)
    let index = try XCTUnwrap(fixture.source.indexPath(for: anchor.item))
    let attributes = try XCTUnwrap(fixture.collection.layoutAttributesForItem(at: index))
    XCTAssertEqual(attributes.frame.minY - fixture.collection.contentOffset.y, anchor.viewportY, accuracy: 2)
    // A second embed/error completes after prepend restoration has finished.
    fixture.rows.heights[anchor.item + 1] = 40
    fixture.rows.heights[anchor.item] = 280
    try await fixture.waitForHeight(anchor.item + 1, expected: initialEmbedHeight - 40)
    try await fixture.waitForHeight(anchor.item, expected: initialAnchorHeight + 200)
    let after = try XCTUnwrap(fixture.collection.layoutAttributesForItem(at: index))
    XCTAssertEqual(after.frame.minY - fixture.collection.contentOffset.y, anchor.viewportY, accuracy: 2)
  }

  func testBottomLockSurvivesComposerInsetGrowth() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    fixture.pinBottom()
    _ = try await fixture.baselineHeight(29)
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
    fixture.collection.contentInset.bottom += 120
    try await fixture.settle()
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
  }

  func testBottomLockSurvivesCoalescedComposerInsets() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    fixture.pinBottom()
    _ = try await fixture.baselineHeight(29)
    fixture.collection.contentInset.bottom += 60
    fixture.collection.contentInset.bottom += 60
    try await fixture.settle()
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
  }

  func testDynamicTypeKeepsVisibleMessageOrigin() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    fixture.collection.contentOffset.y = 900
    try await fixture.settle()
    let (item, y) = fixture.anchor()
    let initialHeight = try await fixture.baselineHeight(item)
    fixture.collection.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    try await fixture.waitForMeasuredChange(item) { $0 > initialHeight + 10 }
    XCTAssertGreaterThan(try fixture.height(item), initialHeight + 10)
    XCTAssertEqual(fixture.viewportY(item), y, accuracy: 2)
  }
}
#endif
