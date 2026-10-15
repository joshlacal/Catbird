#if os(iOS)
import Petrel
import SwiftUI
import Testing
import UIKit

@testable import Catbird

/// Fixtures shared by the post list controller suites.
@MainActor
enum PostListTestSupport {
  static func bookmarkEntries(count: Int) throws -> [PostListEntry] {
    try (0..<count).map { index -> PostListEntry in
      let uri = try ATProtocolURI(uriString: "at://did:plc:scrollfixture/app.bsky.feed.post/\(index)")
      let bookmark = AppBskyBookmarkDefs.BookmarkView(
        subject: .init(uri: uri, cid: CID.fromDAGCBOR(Data("post-\(index)".utf8))),
        item: .appBskyFeedDefsNotFoundPost(.init(uri: uri, notFound: true))
      )
      return .bookmark(EquatableBox(bookmark))
    }
  }

  static func expectOffset(
    _ expected: CGFloat, in controller: PostListCollectionController,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    var offset: CGFloat = .infinity
    repeat {
      try await Task.sleep(for: .milliseconds(20))
      controller.view.layoutIfNeeded()
      controller.collectionView.layoutIfNeeded()
      offset = controller.collectionView.contentOffset.y + controller.collectionView.adjustedContentInset.top
    } while abs(offset - expected) >= 1 && ContinuousClock.now < deadline
    #expect(
      abs(offset - expected) < 1, "Expected normalized offset \(expected), got \(offset)",
      sourceLocation: sourceLocation
    )
  }

  struct PinnedList {
    let window: UIWindow
    let controller: PostListCollectionController
    let collection: UICollectionView
  }

  /// A profile-shaped list in a window, drawing under at least 100 pt of transparent bars:
  /// a 300 pt header, a 44 pt pinned header and 60 rows of 100 pt.
  static func makePinnedProfileList(
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
    controller.setEntries(try bookmarkEntries(count: 60), hasMore: false, isLoadingMore: false, footerState: .hidden)
    window.layoutIfNeeded()
    controller.view.layoutIfNeeded()
    try #require(controller.view.safeAreaInsets.top >= 100)
    // The first snapshot can finish, and apply its offset, after this returns.
    try await expectOffset(0, in: controller)
    return PinnedList(window: window, controller: controller, collection: try #require(controller.collectionView))
  }

  static func scrollAndLayout(_ collection: UICollectionView, to normalizedOffset: CGFloat) async throws {
    collection.setContentOffset(
      CGPoint(x: 0, y: normalizedOffset - collection.adjustedContentInset.top), animated: false
    )
    try await Task.sleep(for: .milliseconds(20))
    collection.layoutIfNeeded()
  }

  /// The pinned header's top, measured from the top of the collection view's bounds.
  static func headerScreenY(in collection: UICollectionView) throws -> CGFloat {
    let header = try #require(collection.supplementaryView(
      forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)
    ))
    return header.frame.minY - collection.contentOffset.y
  }
}
#endif
