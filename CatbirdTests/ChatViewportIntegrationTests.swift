#if os(iOS)
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Real SwiftUI footer overlay plus the production transcript collection.
/// Keyboard reservation is controlled locally; no account or software keyboard
/// preference is required to exercise viewport growth and shrink deterministically.
@MainActor
final class ChatViewportIntegrationTests: XCTestCase {
  @MainActor @Observable
  final class State {
    var footerHeight: CGFloat = 52
    var keyboardHeight: CGFloat = 0
    @ObservationIgnored var footerFrame = CGRect.zero
  }

  final class TranscriptController: UIViewController {
    let collection = ChatTranscriptCollectionView(frame: .zero, collectionViewLayout: ChatAnchoredLayout())
    var source: UICollectionViewDiffableDataSource<Int, Int>!
    let messageCount: Int

    init(messageCount: Int = 50) {
      self.messageCount = messageCount
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
      super.viewDidLoad()
      collection.frame = view.bounds
      collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(collection)
      let registration = UICollectionView.CellRegistration<ChatTranscriptCell, Int> { cell, _, id in
        cell.contentConfiguration = UIHostingConfiguration {
          ChatTranscriptContent(cell: cell) {
            Text("Message \(id)").frame(maxWidth: .infinity, minHeight: 64)
          }
        }.margins(.all, 0)
      }
      source = UICollectionViewDiffableDataSource(collectionView: collection) { collection, index, id in
        collection.dequeueConfiguredReusableCell(using: registration, for: index, item: id)
      }
      var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
      snapshot.appendSections([0])
      snapshot.appendItems(Array(0..<messageCount))
      source.apply(snapshot, animatingDifferences: false)
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      collection.layoutIfNeeded()
    }
  }

  struct Bridge: UIViewControllerRepresentable {
    let controller: TranscriptController
    @Environment(\.chatTranscriptBottomInset) private var bottomInset
    func makeUIViewController(context: Context) -> TranscriptController { controller }
    func updateUIViewController(_ controller: TranscriptController, context: Context) {
      controller.collection.contentInset.bottom = bottomInset
      controller.collection.verticalScrollIndicatorInsets.bottom = bottomInset
    }
  }

  struct Screen: View {
    let state: State
    let controller: TranscriptController
    var body: some View {
      NavigationStack {
        Bridge(controller: controller)
          .chatTranscriptViewport {
            Color.clear.frame(height: state.footerHeight)
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.footerFrame = $0 }
          }
          .navigationTitle("Chat")
          .toolbarTitleDisplayMode(.inline)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Color.clear.frame(height: state.keyboardHeight)
      }
    }
  }

  @MainActor
  final class Fixture {
    let state = State()
    let controller: TranscriptController
    let window: UIWindow
    let host: UIHostingController<Screen>

    init(messageCount: Int = 50) throws {
      controller = TranscriptController(messageCount: messageCount)
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
      host = UIHostingController(rootView: Screen(state: state, controller: controller))
      window.rootViewController = host
      window.isHidden = false
    }

    var collection: UICollectionView { controller.collection }
    var bottom: CGFloat { max(-collection.adjustedContentInset.top,
      collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom) }
    func settle() async throws {
      for _ in 0..<8 {
        try await Task.sleep(for: .milliseconds(20))
        host.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        collection.layoutIfNeeded()
      }
    }
    func pinBottom() {
      let layout = collection.collectionViewLayout as! ChatAnchoredLayout
      layout.preservesSelfSizingAnchor = false
      for _ in 0..<3 {
        collection.contentOffset.y = bottom
        collection.layoutIfNeeded()
      }
      layout.preservesSelfSizingAnchor = true
      collection.layoutIfNeeded()
    }
    func readerAnchor() throws -> ChatVisibleItemAnchor<Int> {
      try XCTUnwrap(ChatVisibleItemAnchor.capture(in: collection,
        itemAt: { self.controller.source.itemIdentifier(for: $0) }, include: { _ in true }))
    }
    func viewportY(_ id: Int) throws -> CGFloat {
      let index = try XCTUnwrap(controller.source.indexPath(for: id))
      return try XCTUnwrap(collection.layoutAttributesForItem(at: index)).frame.minY - collection.contentOffset.y
    }
  }

  func testShortTranscriptCrossesViewportBoundaryWithoutDuplicateBottomSpace() async throws {
    for count in [0, 3] {
      let fixture = try Fixture(messageCount: count)
      try await fixture.settle()
      fixture.pinBottom()
      fixture.state.keyboardHeight = 500
      fixture.state.footerHeight = 100
      try await fixture.settle()
      XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
      XCTAssertEqual(fixture.collection.adjustedContentInset.bottom, fixture.state.footerHeight, accuracy: 2)
      fixture.state.keyboardHeight = 0
      fixture.state.footerHeight = 52
      try await fixture.settle()
      XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
      fixture.window.isHidden = true
    }
  }

  func testComposerHeightConsumesViewportExactlyOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    try await fixture.settle()
    let originalHeight = fixture.collection.bounds.height
    fixture.state.footerHeight += 120
    try await fixture.settle()
    XCTAssertEqual(fixture.collection.bounds.height, originalHeight, accuracy: 2)
    XCTAssertEqual(fixture.collection.contentInset.bottom, fixture.state.footerHeight, accuracy: 2)
    XCTAssertEqual(fixture.collection.adjustedContentInset.bottom, fixture.state.footerHeight, accuracy: 2)
    XCTAssertEqual(fixture.collection.contentInsetAdjustmentBehavior, .never)
    let frame = fixture.collection.convert(fixture.collection.bounds, to: fixture.window)
    XCTAssertEqual(frame.maxY, fixture.state.footerFrame.maxY, accuracy: 2)
    XCTAssertEqual(frame.maxY - fixture.collection.adjustedContentInset.bottom,
      fixture.state.footerFrame.minY, accuracy: 2)
  }

  func testBottomIntentSurvivesComposerAndKeyboardReservationChanges() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    try await fixture.settle()
    fixture.pinBottom()
    fixture.state.footerHeight = 190
    fixture.state.keyboardHeight = 260
    try await fixture.settle()
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
    fixture.state.footerHeight = 52
    fixture.state.keyboardHeight = 0
    try await fixture.settle()
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
    XCTAssertEqual(fixture.collection.adjustedContentInset.bottom, fixture.state.footerHeight, accuracy: 2)
  }

  func testOlderMessageReadingOriginSurvivesGrowingComposerAndKeyboard() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    try await fixture.settle()
    fixture.collection.contentOffset.y = 900
    try await fixture.settle()
    let anchor = try fixture.readerAnchor()
    fixture.state.footerHeight = 210
    fixture.state.keyboardHeight = 240
    try await fixture.settle()
    XCTAssertEqual(try fixture.viewportY(anchor.item), anchor.viewportY, accuracy: 2)
    XCTAssertGreaterThan(fixture.bottom - fixture.collection.contentOffset.y, 100)
    fixture.state.keyboardHeight = 0
    fixture.state.footerHeight = 52
    try await fixture.settle()
    XCTAssertEqual(try fixture.viewportY(anchor.item), anchor.viewportY, accuracy: 2)
  }

  func testRepeatedInterruptedKeyboardReservationsDoNotQueueBottomJump() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    try await fixture.settle()
    fixture.collection.contentOffset.y = 900
    try await fixture.settle()
    let anchor = try fixture.readerAnchor()
    for height in [CGFloat(240), 0, 300, 120, 0] {
      fixture.state.keyboardHeight = height
      try await fixture.settle()
      XCTAssertEqual(try fixture.viewportY(anchor.item), anchor.viewportY, accuracy: 2)
    }
    try await Task.sleep(for: .milliseconds(400))
    fixture.collection.layoutIfNeeded()
    XCTAssertEqual(try fixture.viewportY(anchor.item), anchor.viewportY, accuracy: 2)
  }
  func testFooterRemovalReleasesOnlyItsReservedSpace() async throws {
    let fixture = try Fixture()
    defer { fixture.window.isHidden = true }
    try await fixture.settle()
    fixture.pinBottom()
    let height = fixture.collection.bounds.height
    fixture.state.footerHeight = 0
    try await fixture.settle()
    XCTAssertEqual(fixture.collection.bounds.height, height, accuracy: 2)
    XCTAssertEqual(fixture.collection.adjustedContentInset.bottom, 0, accuracy: 2)
    XCTAssertEqual(fixture.collection.contentOffset.y, fixture.bottom, accuracy: 2)
  }

}
#endif
