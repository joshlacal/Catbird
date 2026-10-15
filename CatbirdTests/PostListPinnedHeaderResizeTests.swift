#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import Catbird

/// A pinned header through changes that move its pin line without a scroll, and through the band
/// where only this layout pins it.
@Suite("Post list pinned header through layout changes")
@MainActor
struct PostListPinnedHeaderResizeTests {
  /// The compositional layout only pins the header once the offset reaches its resting y; the
  /// band above that, where it pins under the bars instead, is this layout's alone.
  @Test("Scrolled step by step through the band above its resting place, the header stays under the bars")
  func pinnedHeaderFollowsEveryStepThroughTheBand() async throws {
    let list = try await PostListTestSupport.makePinnedProfileList()
    defer { list.controller.cancelTasks() }
    let collection = list.collection
    let bars = list.controller.view.safeAreaInsets.top
    let steps = Array(stride(from: 300 - bars - 20, through: 320, by: 10))
    for offset in steps + steps.reversed() {
      collection.setContentOffset(CGPoint(x: 0, y: offset - collection.adjustedContentInset.top), animated: false)
      collection.layoutIfNeeded()
      #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - max(bars, 300 - offset)) < 1, "At offset \(offset)")
    }
  }

  /// A switch to a tab not shown before, or to a short one, lands exactly on the pin offset.
  /// A rotation then lays the content above the header out again at the new width, from
  /// estimates first: a short tab's content shrinks, the offset is clamped, and without help
  /// the profile comes back at the top.
  @Test("A header pinned over a short tab stays pinned through a rotation's size and bar changes")
  func pinnedHeaderStaysPinnedThroughResizes() async throws {
    // 300 pt tall at the window's 390 pt width, and taller when wider, as rewrapped text can be.
    let list = try await PostListTestSupport.makePinnedProfileList(header: AnyView(Color.clear.aspectRatio(390 / 300, contentMode: .fit)))
    let controller = list.controller, collection = list.collection
    defer { controller.cancelTasks() }
    controller.emptyView = AnyView(Color.clear.frame(height: 80))
    controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    func resize(
      width: CGFloat, height: CGFloat = 640, additionalBars: CGFloat
    ) async throws -> (bars: CGFloat, restingY: CGFloat) {
      list.window.frame.size = CGSize(width: width, height: height)
      controller.additionalSafeAreaInsets = UIEdgeInsets(top: additionalBars, left: 0, bottom: 0, right: 0)
      list.window.layoutIfNeeded()
      // The header is measured again once a pass has shown it, a turn or two later.
      for _ in 0..<5 {
        try await Task.sleep(for: .milliseconds(40))
        collection.layoutIfNeeded()
      }
      let layout = try #require(collection.collectionViewLayout as? PostListPinnedHeaderLayout)
      return (controller.view.safeAreaInsets.top, try #require(layout.pinnedHeaderRestingY))
    }
    var geometry = try await resize(width: 390, additionalBars: 100)
    try await PostListTestSupport.scrollAndLayout(collection, to: geometry.restingY - geometry.bars)
    #expect(controller.isHeaderPinned)

    // Wider, with shorter bars: the content above the header grows, and the list follows it.
    geometry = try await resize(width: 700, additionalBars: 60)
    #expect(geometry.restingY > 500)
    try await PostListTestSupport.expectOffset(geometry.restingY - geometry.bars, in: controller)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - geometry.bars) < 1)
    #expect(controller.isHeaderPinned)

    // And back.
    geometry = try await resize(width: 390, additionalBars: 100)
    try await PostListTestSupport.expectOffset(geometry.restingY - geometry.bars, in: controller)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - geometry.bars) < 1)
    #expect(controller.isHeaderPinned)

    // Taller only, as an iPad rotating to portrait: the pin offset stays put, but the short tab
    // no longer reaches the old offset, which UIKit clamps.
    geometry = try await resize(width: 390, height: 1_000, additionalBars: 100)
    try await PostListTestSupport.expectOffset(geometry.restingY - geometry.bars, in: controller)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - geometry.bars) < 1)
    #expect(controller.isHeaderPinned)
    geometry = try await resize(width: 390, additionalBars: 100)
    try await PostListTestSupport.expectOffset(geometry.restingY - geometry.bars, in: controller)
    #expect(controller.isHeaderPinned)

    // A header in the content is left to the resize.
    try await PostListTestSupport.scrollAndLayout(collection, to: 40)
    geometry = try await resize(width: 700, additionalBars: 60)
    #expect(!controller.isHeaderPinned)
    #expect(try PostListTestSupport.headerScreenY(in: collection) > geometry.bars + 1)
  }

  @Test("A pinned header stays pinned when the content above it grows")
  func pinnedHeaderStaysPinnedWhenContentAboveGrows() async throws {
    let list = try await PostListTestSupport.makePinnedProfileList()
    let controller = list.controller, collection = list.collection
    defer { controller.cancelTasks() }
    let bars = controller.view.safeAreaInsets.top
    let entries = try PostListTestSupport.bookmarkEntries(count: 60)
    func setHeaderHeight(_ height: CGFloat) {
      controller.headerView = AnyView(Color.clear.frame(height: height))
      controller.setEntries(entries, hasMore: false, isLoadingMore: false, footerState: .hidden)
    }
    try await PostListTestSupport.scrollAndLayout(collection, to: 300 - bars)
    #expect(controller.isHeaderPinned)

    // Taller (more profile information loaded, or larger text): the list follows the pin offset.
    setHeaderHeight(420)
    try await PostListTestSupport.expectOffset(420 - bars, in: controller)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - bars) < 1)
    #expect(controller.isHeaderPinned)
    // Shorter: UIKit keeps the rows in place, which keeps the header at the pin offset.
    setHeaderHeight(300)
    try await PostListTestSupport.expectOffset(300 - bars, in: controller)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - bars) < 1)
    #expect(controller.isHeaderPinned)

    // A header in the content moves with the content above it.
    try await PostListTestSupport.scrollAndLayout(collection, to: 100)
    setHeaderHeight(420)
    try await PostListTestSupport.expectOffset(100, in: controller)
    #expect(!controller.isHeaderPinned)
  }
}
#endif
