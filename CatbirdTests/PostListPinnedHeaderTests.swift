#if os(iOS)
import Petrel
import SwiftUI
import Testing
import UIKit

@testable import Catbird

@Suite("Post list pinned header")
@MainActor
struct PostListPinnedHeaderTests {
  @Test("Lists without a pinned header keep one section, no section header and the bookmark swipe action")
  func listsWithoutPinnedHeaderAreUnchanged() throws {
    let controller = PostListCollectionController()
    controller.headerView = AnyView(Color.clear.frame(height: 120))
    controller.rowViewBuilder = { _ in AnyView(Color.clear.frame(height: 100)) }
    controller.onRemoveBookmark = { _ in true }
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
    defer { controller.cancelTasks() }
    controller.setEntries(try PostListTestSupport.bookmarkEntries(count: 5), hasMore: true, isLoadingMore: true, footerState: .loading)
    controller.view.layoutIfNeeded()
    let collection = try #require(controller.collectionView)

    #expect(collection.numberOfSections == 1)
    // Header, five rows, footer.
    #expect(collection.numberOfItems(inSection: 0) == 7)
    #expect(collection.collectionViewLayout.layoutAttributesForSupplementaryView(
      ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)
    ) == nil)

    let plain = controller.listConfiguration(hasPinnedHeader: false)
    #expect(plain.headerMode == .none)
    #expect(!plain.showsSeparators)
    #expect(plain.backgroundColor == .clear)
    #expect(plain.trailingSwipeActionsConfigurationProvider != nil)
    let swipe = try #require(controller.trailingSwipeActions(for: IndexPath(item: 1, section: 0)))
    #expect(swipe.actions.map(\.title) == ["Remove Bookmark"])
    #expect(controller.trailingSwipeActions(for: IndexPath(item: 0, section: 0)) == nil)

    controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    controller.emptyView = AnyView(Text("Nothing here"))
    controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    controller.view.layoutIfNeeded()
    #expect(collection.numberOfSections == 1)
    #expect(collection.numberOfItems(inSection: 0) == 2)
  }

  @Test("A pinned header puts the rows in a second section that has the pinned section header")
  func pinnedHeaderAddsContentSection() throws {
    let controller = PostListCollectionController()
    controller.headerView = AnyView(Color.clear.frame(height: 120))
    controller.pinnedHeaderView = AnyView(Color.clear.frame(height: 44))
    controller.rowViewBuilder = { _ in AnyView(Color.clear.frame(height: 100)) }
    controller.onRemoveBookmark = { _ in true }
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
    defer { controller.cancelTasks() }
    controller.setEntries(try PostListTestSupport.bookmarkEntries(count: 5), hasMore: true, isLoadingMore: true, footerState: .loading)
    controller.view.layoutIfNeeded()
    let collection = try #require(controller.collectionView)
    let layout = collection.collectionViewLayout

    #expect(collection.numberOfSections == 2)
    #expect(collection.numberOfItems(inSection: 0) == 1)
    // Five rows and the footer.
    #expect(collection.numberOfItems(inSection: 1) == 6)
    let kind = UICollectionView.elementKindSectionHeader
    #expect(layout.layoutAttributesForSupplementaryView(ofKind: kind, at: IndexPath(item: 0, section: 0)) == nil)
    let header = try #require(layout.layoutAttributesForSupplementaryView(ofKind: kind, at: IndexPath(item: 0, section: 1)))
    #expect(header.zIndex > 0)
    let pinned = controller.listConfiguration(hasPinnedHeader: true)
    #expect(pinned.headerMode == .supplementary)
    #expect(pinned.headerTopPadding == 0)
    #expect(!pinned.showsSeparators)
    let swipe = try #require(controller.trailingSwipeActions(for: IndexPath(item: 0, section: 1)))
    #expect(swipe.actions.map(\.title) == ["Remove Bookmark"])
    #expect(controller.trailingSwipeActions(for: IndexPath(item: 0, section: 0)) == nil)

    // The empty view (a profile tab's own content) sits in the content section too.
    controller.emptyView = AnyView(Text("Nothing here"))
    controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    controller.view.layoutIfNeeded()
    #expect(collection.numberOfSections == 2)
    #expect(collection.numberOfItems(inSection: 0) == 1)
    #expect(collection.numberOfItems(inSection: 1) == 1)

    controller.pinnedHeaderView = nil
    controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    controller.view.layoutIfNeeded()
    #expect(collection.numberOfSections == 1)
    #expect(collection.numberOfItems(inSection: 0) == 2)
    #expect(layout.layoutAttributesForSupplementaryView(ofKind: kind, at: IndexPath(item: 0, section: 0)) == nil)
  }

  @Test("Under a transparent bar the header pins below the bars, not at the top of the screen")
  func pinnedHeaderPinsBelowBars() async throws {
    let list = try await makePinnedProfileList()
    defer { list.controller.cancelTasks() }
    let collection = list.collection
    let bars = list.controller.view.safeAreaInsets.top
    let pinOffset = 300 - bars
    let layout = try #require(collection.collectionViewLayout as? PostListPinnedHeaderLayout)
    // The list draws under the bars, so the compositional layout alone would pin at 0.
    #expect(collection.contentInset.top == -bars)
    #expect(collection.adjustedContentInset.top == 0)
    #expect(layout.pinInset == bars)
    let restingY = try #require(layout.pinnedHeaderRestingY)
    #expect(abs(restingY - 300) < 1)
    #expect(abs((layout.pinOffset ?? -1) - pinOffset) < 1)

    // Header still in view: it scrolls with the content.
    try await scrollAndLayout(collection, to: pinOffset - 50)
    #expect(abs(try headerScreenY(in: collection) - (bars + 50)) < 1)
    // Scrolled past the pin offset: it stays right under the bars.
    try await scrollAndLayout(collection, to: pinOffset + 300)
    #expect(abs(try headerScreenY(in: collection) - bars) < 1)
    try await scrollAndLayout(collection, to: 2_000)
    #expect(abs(try headerScreenY(in: collection) - bars) < 1)
    // And comes back down with the content.
    try await scrollAndLayout(collection, to: 0)
    #expect(abs(try headerScreenY(in: collection) - 300) < 1)
  }

  /// The compositional layout only pins the header once the offset reaches its resting y; the
  /// band above that, where it pins under the bars instead, is this layout's alone.
  @Test("Scrolled step by step through the band above its resting place, the header stays under the bars")
  func pinnedHeaderFollowsEveryStepThroughTheBand() async throws {
    let list = try await makePinnedProfileList()
    defer { list.controller.cancelTasks() }
    let collection = list.collection
    let bars = list.controller.view.safeAreaInsets.top
    let steps = Array(stride(from: 300 - bars - 20, through: 320, by: 10))
    for offset in steps + steps.reversed() {
      collection.setContentOffset(CGPoint(x: 0, y: offset - collection.adjustedContentInset.top), animated: false)
      collection.layoutIfNeeded()
      #expect(abs(try headerScreenY(in: collection) - max(bars, 300 - offset)) < 1, "At offset \(offset)")
    }
  }

  /// A switch to a tab not shown before, or to a short one, lands exactly on the pin offset.
  /// A rotation then lays the content above the header out again at the new width, from
  /// estimates first: a short tab's content shrinks, the offset is clamped, and without help
  /// the profile comes back at the top.
  @Test("A header pinned over a short tab stays pinned through a rotation's size and bar changes")
  func pinnedHeaderStaysPinnedThroughResizes() async throws {
    // 300 pt tall at the window's 390 pt width, and taller when wider, as rewrapped text can be.
    let list = try await makePinnedProfileList(header: AnyView(Color.clear.aspectRatio(390 / 300, contentMode: .fit)))
    let controller = list.controller, collection = list.collection
    defer { controller.cancelTasks() }
    controller.emptyView = AnyView(Color.clear.frame(height: 80))
    controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    func resize(width: CGFloat, additionalBars: CGFloat) async throws -> (bars: CGFloat, restingY: CGFloat) {
      list.window.frame.size.width = width
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
    try await scrollAndLayout(collection, to: geometry.restingY - geometry.bars)
    #expect(controller.isHeaderPinned)

    // Wider, with shorter bars: the content above the header grows, and the list follows it.
    geometry = try await resize(width: 700, additionalBars: 60)
    #expect(geometry.restingY > 500)
    try await PostListTestSupport.expectOffset(geometry.restingY - geometry.bars, in: controller)
    #expect(abs(try headerScreenY(in: collection) - geometry.bars) < 1)
    #expect(controller.isHeaderPinned)

    // And back.
    geometry = try await resize(width: 390, additionalBars: 100)
    try await PostListTestSupport.expectOffset(geometry.restingY - geometry.bars, in: controller)
    #expect(abs(try headerScreenY(in: collection) - geometry.bars) < 1)
    #expect(controller.isHeaderPinned)

    // A header in the content is left to the resize.
    try await scrollAndLayout(collection, to: 40)
    geometry = try await resize(width: 700, additionalBars: 60)
    #expect(!controller.isHeaderPinned)
    #expect(try headerScreenY(in: collection) > geometry.bars + 1)
  }

  @Test("A pinned header stays pinned when the content above it grows")
  func pinnedHeaderStaysPinnedWhenContentAboveGrows() async throws {
    let list = try await makePinnedProfileList()
    let controller = list.controller, collection = list.collection
    defer { controller.cancelTasks() }
    let bars = controller.view.safeAreaInsets.top
    let entries = try PostListTestSupport.bookmarkEntries(count: 60)
    func setHeaderHeight(_ height: CGFloat) {
      controller.headerView = AnyView(Color.clear.frame(height: height))
      controller.setEntries(entries, hasMore: false, isLoadingMore: false, footerState: .hidden)
    }
    try await scrollAndLayout(collection, to: 300 - bars)
    #expect(controller.isHeaderPinned)

    // Taller (more profile information loaded, or larger text): the list follows the pin offset.
    setHeaderHeight(420)
    try await PostListTestSupport.expectOffset(420 - bars, in: controller)
    #expect(abs(try headerScreenY(in: collection) - bars) < 1)
    #expect(controller.isHeaderPinned)
    // Shorter: UIKit keeps the rows in place, which keeps the header at the pin offset.
    setHeaderHeight(300)
    try await PostListTestSupport.expectOffset(300 - bars, in: controller)
    #expect(abs(try headerScreenY(in: collection) - bars) < 1)
    #expect(controller.isHeaderPinned)

    // A header in the content moves with the content above it.
    try await scrollAndLayout(collection, to: 100)
    setHeaderHeight(420)
    try await PostListTestSupport.expectOffset(100, in: controller)
    #expect(!controller.isHeaderPinned)
  }

  @Test("Switching keys keeps a pinned header pinned and an unpinned header in place")
  func pinnedHeaderSurvivesKeySwitches() async throws {
    let list = try await makePinnedProfileList()
    let controller = list.controller, collection = list.collection
    defer { controller.cancelTasks() }
    let pinOffset = 300 - controller.view.safeAreaInsets.top
    let entries = try PostListTestSupport.bookmarkEntries(count: 60)
    controller.emptyView = AnyView(Color.clear.frame(height: 80))
    func show(_ key: String, _ rows: [PostListEntry]) {
      controller.updateScrollPosition(key: key, requestID: 0)
      controller.setEntries(rows, hasMore: false, isLoadingMore: false, footerState: .hidden)
    }

    // Pinned, deep in Posts; a short tab still pins, thanks to the minimum content height.
    try await scrollAndLayout(collection, to: 900)
    show("profile/replies", [])
    try await PostListTestSupport.expectOffset(pinOffset, in: controller)
    #expect(abs(try headerScreenY(in: collection) - controller.view.safeAreaInsets.top) < 1)
    #expect(collection.contentSize.height >= pinOffset + collection.bounds.height - collection.adjustedContentInset.bottom - 1)
    // Back to Posts while pinned: its own, deeper place.
    show("profile/posts", entries)
    try await PostListTestSupport.expectOffset(900, in: controller)

    // Header in view: every tab keeps that header position.
    try await scrollAndLayout(collection, to: pinOffset - 30)
    show("profile/replies", [])
    try await PostListTestSupport.expectOffset(pinOffset - 30, in: controller)
    show("profile/posts", entries)
    try await PostListTestSupport.expectOffset(pinOffset - 30, in: controller)
  }

  /// Otherwise the collection view drops the header view, and the picker's SwiftUI state with it,
  /// for the moment a switch to a short tab leaves the offset past the end of the content.
  @Test("A pinned header stays laid out while the offset is past the end of shorter content")
  func pinnedHeaderSurvivesShortContent() async throws {
    let list = try await makePinnedProfileList()
    defer { list.controller.cancelTasks() }
    let collection = list.collection
    let bars = list.controller.view.safeAreaInsets.top
    let kind = UICollectionView.elementKindSectionHeader
    try await scrollAndLayout(collection, to: 900)

    list.controller.emptyView = AnyView(Color.clear.frame(height: 80))
    list.controller.setEntries([], hasMore: false, isLoadingMore: false, footerState: .hidden)
    collection.contentOffset.y = 900
    let attributes = try #require(collection.collectionViewLayout.layoutAttributesForElements(in: collection.bounds))
    let header = try #require(attributes.first { $0.representedElementKind == kind })
    #expect(abs(header.frame.minY - (900 + bars)) < 1)
    collection.layoutIfNeeded()
    #expect(collection.supplementaryView(forElementKind: kind, at: IndexPath(item: 0, section: 1)) != nil)
  }

  struct RestorationCase: Sendable, CustomTestStringConvertible {
    let saved: CGFloat?
    let current: CGFloat
    let pinOffset: CGFloat?
    let expected: CGFloat
    var testDescription: String {
      "saved \(saved.map { "\($0)" } ?? "none"), at \(current), pins at \(pinOffset.map { "\($0)" } ?? "none")"
    }
  }

  @Test("Tab switch offsets", arguments: [
    // No pinned header: each key keeps its own place.
    RestorationCase(saved: nil, current: 0, pinOffset: nil, expected: 0),
    RestorationCase(saved: 320, current: 80, pinOffset: nil, expected: 320),
    // Header in view: it stays where it is, whatever the target's own place.
    RestorationCase(saved: nil, current: 120, pinOffset: 200, expected: 120),
    RestorationCase(saved: 900, current: 120, pinOffset: 200, expected: 120),
    RestorationCase(saved: nil, current: 199, pinOffset: 200, expected: 199),
    // Pinned: at least the pin offset, or the target's own place further down.
    RestorationCase(saved: nil, current: 600, pinOffset: 200, expected: 200),
    RestorationCase(saved: 40, current: 600, pinOffset: 200, expected: 200),
    RestorationCase(saved: 900, current: 600, pinOffset: 200, expected: 900),
    RestorationCase(saved: nil, current: 199.8, pinOffset: 200, expected: 200)
  ])
  func restorationRule(_ rule: RestorationCase) {
    #expect(PostListPinnedScrollRestoration.offset(
      saved: rule.saved, current: rule.current, pinOffset: rule.pinOffset
    ) == rule.expected)
  }

  private struct PinnedList {
    let window: UIWindow
    let controller: PostListCollectionController
    let collection: UICollectionView
  }

  /// A profile-shaped list in a window, drawing under at least 100 pt of transparent bars:
  /// a 300 pt header, a 44 pt pinned header and 60 rows of 100 pt.
  private func makePinnedProfileList(
    header: AnyView = AnyView(Color.clear.frame(height: 300))
  ) async throws -> PinnedList {
    let controller = PostListCollectionController()
    controller.extendsUnderTopBar = true
    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 100, left: 0, bottom: 0, right: 0)
    controller.headerView = header
    controller.pinnedHeaderView = AnyView(Color.clear.frame(height: 44))
    controller.rowViewBuilder = { _ in AnyView(Color.clear.frame(height: 100)) }
    // Safe-area insets only reach a view in a window.
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
    window.rootViewController = controller
    window.isHidden = false
    controller.updateScrollPosition(key: "profile/posts", requestID: 0)
    controller.setEntries(try PostListTestSupport.bookmarkEntries(count: 60), hasMore: false, isLoadingMore: false, footerState: .hidden)
    window.layoutIfNeeded()
    controller.view.layoutIfNeeded()
    try #require(controller.view.safeAreaInsets.top >= 100)
    // The first snapshot can finish, and apply its offset, after this returns.
    try await PostListTestSupport.expectOffset(0, in: controller)
    return PinnedList(window: window, controller: controller, collection: try #require(controller.collectionView))
  }

  private func scrollAndLayout(_ collection: UICollectionView, to normalizedOffset: CGFloat) async throws {
    collection.setContentOffset(
      CGPoint(x: 0, y: normalizedOffset - collection.adjustedContentInset.top), animated: false
    )
    try await Task.sleep(for: .milliseconds(20))
    collection.layoutIfNeeded()
  }

  /// The pinned header's top, measured from the top of the collection view's bounds.
  private func headerScreenY(in collection: UICollectionView) throws -> CGFloat {
    let header = try #require(collection.supplementaryView(
      forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)
    ))
    return header.frame.minY - collection.contentOffset.y
  }
}
#endif
