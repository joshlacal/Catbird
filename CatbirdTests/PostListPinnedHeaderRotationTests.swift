#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import Catbird

/// A deep-scrolled list with a pinned header through an iPhone rotation, step by step in the
/// order UIKit and SwiftUI deliver it to the profile on an iPhone 17 Pro.
@Suite("Post list pinned header through a rotation")
@MainActor
struct PostListPinnedHeaderRotationTests {
  /// The width each row was last built for. The profile's rows capture the width its
  /// GeometryReader reports, so a row built mid-rotation keeps that width.
  @MainActor
  final class RowWidths {
    var byID: [String: CGFloat] = [:]
  }

  @MainActor
  struct Rotation {
    let window: UIWindow
    let controller: PostListCollectionController
    let collection: UICollectionView
    let entries: [PostListEntry]
    let rowWidths = RowWidths()

    /// What SwiftUI sends the list when the screen it measures is `screenWidth` wide: rows
    /// capped at that width, and at most 600 pt, as the profile's are.
    func swiftUIUpdate(screenWidth: CGFloat) {
      let width = min(screenWidth, 600)
      let rowWidths = rowWidths
      controller.applySwiftUIUpdate {
        controller.rowViewBuilder = { entry in
          rowWidths.byID[entry.id] = width
          let index = Int(entry.id.split(separator: "/").last ?? "") ?? 0
          // 90 to 210 pt tall at 402 pt wide, never the list's estimate, and another height at
          // another width.
          let height = CGFloat(90 + index % 4 * 40)
          return AnyView(Color.clear.aspectRatio(402 / height, contentMode: .fit).frame(maxWidth: width))
        }
        controller.setEntries(entries, hasMore: false, isLoadingMore: false, footerState: .hidden)
      }
    }

    /// One step of a rotation: UIKit lays the list out with its new insets (and size), then
    /// SwiftUI, if the screen it measures changed, rebuilds the list's content.
    func step(size: CGSize? = nil, insets: UIEdgeInsets, screenWidth: CGFloat? = nil) async throws {
      if let size { window.frame.size = size }
      controller.additionalSafeAreaInsets = insets
      window.layoutIfNeeded()
      if let screenWidth {
        swiftUIUpdate(screenWidth: screenWidth)
        window.layoutIfNeeded()
      }
      for _ in 0..<3 {
        try await Task.sleep(for: .milliseconds(30))
        collection.layoutIfNeeded()
      }
    }

    /// To landscape left: the shorter bars and a side inset on one side only, at the portrait
    /// size, which SwiftUI passes on as a 340 pt wide screen. Then the bottom inset, then the
    /// side inset moves out of the list's view, which takes the landscape size inside it.
    func rotateToLandscape() async throws {
      try await step(insets: UIEdgeInsets(top: 78, left: 62, bottom: 0, right: 0), screenWidth: 340)
      try await step(insets: UIEdgeInsets(top: 78, left: 62, bottom: 20, right: 0), screenWidth: 750)
      try await step(insets: UIEdgeInsets(top: 78, left: 0, bottom: 20, right: 0))
      try await step(
        size: CGSize(width: 750, height: 382), insets: UIEdgeInsets(top: 78, left: 0, bottom: 0, right: 0),
        screenWidth: 750
      )
    }

    /// Back to portrait: the taller bars at the landscape size first, then the portrait size.
    func rotateToPortrait() async throws {
      try await step(insets: UIEdgeInsets(top: 116, left: 0, bottom: 0, right: 0), screenWidth: 874)
      try await step(
        size: CGSize(width: 402, height: 840), insets: UIEdgeInsets(top: 116, left: 0, bottom: 0, right: 0),
        screenWidth: 402
      )
    }

    /// The bars' height: the inset this test adds, over the host's own.
    var bars: CGFloat { controller.view.safeAreaInsets.top }

    /// The visible rows' frames by id, with y measured from the top of the bounds.
    func visibleRowFrames() -> [String: CGRect] {
      var frames: [String: CGRect] = [:]
      for indexPath in collection.indexPathsForVisibleItems where indexPath.section == 1 {
        guard let cell = collection.cellForItem(at: indexPath), indexPath.item < entries.count else { continue }
        let frame = cell.frame.offsetBy(dx: 0, dy: -collection.contentOffset.y)
        if frame.maxY > 0, frame.minY < collection.bounds.height {
          frames[entries[indexPath.item].id] = frame
        }
      }
      return frames
    }
  }

  /// A portrait list, 402 by 840 under 116 pt of bars, with a 400 pt profile header, a 44 pt
  /// pinned header and 40 rows, scrolled through to its middle so its rows are measured.
  func makeRotation() async throws -> Rotation {
    let controller = PostListCollectionController()
    controller.extendsUnderTopBar = true
    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 116, left: 0, bottom: 0, right: 0)
    controller.headerView = AnyView(Color.clear.frame(height: 400))
    controller.pinnedHeaderView = AnyView(Color.clear.frame(height: 44))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 840))
    window.rootViewController = controller
    window.isHidden = false
    controller.updateScrollPosition(key: "profile/posts", requestID: 0)
    let rotation = Rotation(
      window: window, controller: controller, collection: try #require(controller.collectionView),
      entries: try PostListTestSupport.bookmarkEntries(count: 40)
    )
    rotation.swiftUIUpdate(screenWidth: 402)
    window.layoutIfNeeded()
    try await PostListTestSupport.expectOffset(0, in: controller)
    for offset in stride(from: 0, through: 1_400, by: 100) {
      try await PostListTestSupport.scrollAndLayout(rotation.collection, to: CGFloat(offset))
    }
    try #require(controller.isHeaderPinned)
    return rotation
  }

  /// Laid out again from estimates mid-rotation, the list lost the reader's place, and rows it
  /// reached while the side inset sat on one side only were built for the 340 pt screen SwiftUI
  /// measured then. They kept that width, drawn inset on both sides of their cells.
  @Test("A rotation to landscape and back brings the reader back to the same rows, in the same place")
  func rotationKeepsTheReadersPlace() async throws {
    let rotation = try await makeRotation()
    defer { rotation.controller.cancelTasks() }
    let before = rotation.visibleRowFrames()
    try #require(before.count >= 4)

    try await rotation.rotateToLandscape()
    try await rotation.rotateToPortrait()

    let after = rotation.visibleRowFrames()
    #expect(after.keys.sorted() == before.keys.sorted(), "The same rows are on screen")
    for (id, frame) in before {
      let top = after[id]?.minY ?? .infinity
      #expect(abs(top - frame.minY) < 1, "Row \(id) at \(frame.minY) before, \(top) after")
    }
    for id in after.keys {
      let width = rotation.rowWidths.byID[id] ?? 0
      #expect(width >= 402, "Row \(id) on screen was built for a \(width) pt wide screen")
    }
    #expect(rotation.controller.isHeaderPinned)
    #expect(abs(try PostListTestSupport.headerScreenY(in: rotation.collection) - rotation.bars) < 1)
  }

  /// The bars change height without a resize, as they do at the start of a rotation. The pin
  /// line and the content's minimum height follow them, so a short tab pinned at the pin offset
  /// stays pinned.
  @Test("When only the bars change, a header pinned over a short tab follows them and stays pinned")
  func pinnedHeaderFollowsTheBars() async throws {
    let list = try await PostListTestSupport.makePinnedProfileList()
    let controller = list.controller, collection = list.collection
    defer { controller.cancelTasks() }
    controller.emptyView = AnyView(Color.clear.frame(height: 80))
    controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    func setBars(_ additional: CGFloat) async throws -> CGFloat {
      controller.additionalSafeAreaInsets = UIEdgeInsets(top: additional, left: 0, bottom: 0, right: 0)
      list.window.layoutIfNeeded()
      for _ in 0..<3 {
        try await Task.sleep(for: .milliseconds(30))
        collection.layoutIfNeeded()
      }
      return controller.view.safeAreaInsets.top
    }
    var bars = controller.view.safeAreaInsets.top
    try await PostListTestSupport.scrollAndLayout(collection, to: 300 - bars)
    #expect(controller.isHeaderPinned)

    for additional: CGFloat in [60, 100] {
      bars = try await setBars(additional)
      try await PostListTestSupport.expectOffset(300 - bars, in: controller)
      #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - bars) < 1, "Bars \(bars)")
      #expect(controller.isHeaderPinned, "Bars \(bars)")
    }
  }
}
#endif
