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

  @Test("Without a pinned header the installed layout matches the plain list layout it replaced")
  func layoutMatchesThePlainListLayout() async throws {
    let controller = PostListCollectionController()
    controller.headerView = AnyView(Color.clear.frame(height: 120))
    controller.rowViewBuilder = { entry in
      let index = Int(entry.id.split(separator: "/").last ?? "") ?? 0
      return AnyView(Color.clear.frame(height: CGFloat(40 + index % 4 * 20)))
    }
    controller.onRemoveBookmark = { _ in true }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
    window.rootViewController = controller
    window.isHidden = false
    defer { controller.cancelTasks() }
    // Header, six rows and the footer all fit, so every item is measured in both layouts.
    controller.setEntries(try PostListTestSupport.bookmarkEntries(count: 6), hasMore: true, isLoadingMore: true, footerState: .loading)
    let collection = try #require(controller.collectionView)
    func settle() async throws {
      for _ in 0..<5 {
        try await Task.sleep(for: .milliseconds(20))
        collection.layoutIfNeeded()
      }
    }
    func frames() -> [String: CGRect] {
      let attributes = collection.collectionViewLayout.layoutAttributesForElements(
        in: CGRect(x: 0, y: -1_000, width: 390, height: 10_000)
      ) ?? []
      return Dictionary(uniqueKeysWithValues: attributes.map {
        ("\($0.representedElementCategory.rawValue) \($0.representedElementKind ?? "") \($0.indexPath)", $0.frame)
      })
    }
    try await settle()
    let installed = frames()
    let installedSize = collection.contentSize
    // Header, rows and footer cells, besides the list's decoration views.
    #expect(installed.keys.filter { $0.hasPrefix("\(UICollectionView.ElementCategory.cell.rawValue) ") }.count == 8)

    // The layout before the pinned header: one list layout for the whole collection view.
    var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
    configuration.backgroundColor = .clear
    configuration.showsSeparators = false
    configuration.trailingSwipeActionsConfigurationProvider = { _ in nil }
    collection.setCollectionViewLayout(UICollectionViewCompositionalLayout.list(using: configuration), animated: false)
    try await settle()
    let reference = frames()
    #expect(Set(reference.keys) == Set(installed.keys))
    for (key, frame) in reference {
      let other = try #require(installed[key])
      #expect(abs(frame.minY - other.minY) < 0.5 && abs(frame.height - other.height) < 0.5, "\(key)")
      #expect(abs(frame.minX - other.minX) < 0.5 && abs(frame.width - other.width) < 0.5, "\(key)")
    }
    #expect(abs(collection.contentSize.height - installedSize.height) < 0.5)
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
    let list = try await PostListTestSupport.makePinnedProfileList()
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
    try await PostListTestSupport.scrollAndLayout(collection, to: pinOffset - 50)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - (bars + 50)) < 1)
    // Scrolled past the pin offset: it stays right under the bars.
    try await PostListTestSupport.scrollAndLayout(collection, to: pinOffset + 300)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - bars) < 1)
    try await PostListTestSupport.scrollAndLayout(collection, to: 2_000)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - bars) < 1)
    // And comes back down with the content.
    try await PostListTestSupport.scrollAndLayout(collection, to: 0)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - 300) < 1)
  }

  #if compiler(>=6.2)
  @Test("The edge effect reaches behind the header only while it is pinned; other lists keep their edge style")
  func edgeEffectFollowsThePinnedHeader() async throws {
    guard #available(iOS 26.0, *) else { return }
    let list = try await PostListTestSupport.makePinnedProfileList()
    defer { list.controller.cancelTasks() }
    let collection = list.collection
    let bars = list.controller.view.safeAreaInsets.top
    func headerHasEdgeContainer() throws -> Bool {
      try #require(collection.supplementaryView(
        forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)
      )).interactions.contains { $0 is UIScrollEdgeElementContainerInteraction }
    }
    #expect(collection.topEdgeEffect.style == .soft)
    #expect(try !headerHasEdgeContainer())

    try await PostListTestSupport.scrollAndLayout(collection, to: 300 - bars + 200)
    #expect(list.controller.isHeaderPinned)
    // Soft while pinned too: the hard edge would take the touches meant for the header.
    #expect(collection.topEdgeEffect.style == .soft)
    #expect(try headerHasEdgeContainer())

    try await PostListTestSupport.scrollAndLayout(collection, to: 100)
    #expect(!list.controller.isHeaderPinned)
    #expect(try !headerHasEdgeContainer())

    let plain = PostListCollectionController()
    plain.loadViewIfNeeded()
    #expect(try #require(plain.collectionView).topEdgeEffect.style == .automatic)
  }
  #endif

  @Test("Switching keys keeps a pinned header pinned and an unpinned header in place")
  func pinnedHeaderSurvivesKeySwitches() async throws {
    let list = try await PostListTestSupport.makePinnedProfileList()
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
    try await PostListTestSupport.scrollAndLayout(collection, to: 900)
    show("profile/replies", [])
    try await PostListTestSupport.expectOffset(pinOffset, in: controller)
    #expect(abs(try PostListTestSupport.headerScreenY(in: collection) - controller.view.safeAreaInsets.top) < 1)
    #expect(collection.contentSize.height >= pinOffset + collection.bounds.height - collection.adjustedContentInset.bottom - 1)
    // Back to Posts while pinned: its own, deeper place.
    show("profile/posts", entries)
    try await PostListTestSupport.expectOffset(900, in: controller)

    // Header in view: every tab keeps that header position.
    try await PostListTestSupport.scrollAndLayout(collection, to: pinOffset - 30)
    show("profile/replies", [])
    try await PostListTestSupport.expectOffset(pinOffset - 30, in: controller)
    show("profile/posts", entries)
    try await PostListTestSupport.expectOffset(pinOffset - 30, in: controller)

    // Another scope (another profile or account) is not a tab switch: it gets its own place.
    try await PostListTestSupport.scrollAndLayout(collection, to: 900)
    controller.updateScrollPosition(key: "other/posts", scope: "other", requestID: 0)
    controller.setEntries(entries, hasMore: false, isLoadingMore: false, footerState: .hidden)
    try await PostListTestSupport.expectOffset(0, in: controller)
  }

  /// Otherwise the collection view drops the header view, and the picker's SwiftUI state with it,
  /// for the moment a switch to a short tab leaves the offset past the end of the content.
  @Test("A pinned header stays laid out while the offset is past the end of shorter content")
  func pinnedHeaderSurvivesShortContent() async throws {
    let list = try await PostListTestSupport.makePinnedProfileList()
    defer { list.controller.cancelTasks() }
    let collection = list.collection
    let bars = list.controller.view.safeAreaInsets.top
    let kind = UICollectionView.elementKindSectionHeader
    try await PostListTestSupport.scrollAndLayout(collection, to: 900)

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
    var isSameScope = true
    var testDescription: String {
      let place = "saved \(saved.map { "\($0)" } ?? "none"), at \(current), pins at \(pinOffset.map { "\($0)" } ?? "none")"
      return isSameScope ? place : place + ", another scope"
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
    RestorationCase(saved: nil, current: 199.8, pinOffset: 200, expected: 200),
    // Another scope: its own place, pinned or not.
    RestorationCase(saved: nil, current: 600, pinOffset: 200, expected: 0, isSameScope: false),
    RestorationCase(saved: 320, current: 120, pinOffset: 200, expected: 320, isSameScope: false)
  ])
  func restorationRule(_ rule: RestorationCase) {
    #expect(PostListPinnedScrollRestoration.offset(
      saved: rule.saved, current: rule.current, pinOffset: rule.pinOffset, isSameScope: rule.isSameScope
    ) == rule.expected)
  }
}
#endif
