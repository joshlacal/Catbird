#if os(iOS)
import Petrel
import SwiftUI
import Testing
import UIKit

@testable import Catbird

@Suite("Secondary post list scrolling")
@MainActor
struct PostListCollectionControllerTests {
  @Test("Profile lists cancel only the top inset and keep automatic adjustment")
  func underTopBarInsetMode() throws {
    let plain = PostListCollectionController()
    plain.loadViewIfNeeded()
    #expect(try #require(plain.collectionView).contentInsetAdjustmentBehavior == .automatic)

    // .never would hand cells the safe area they overlap; UIHostingConfiguration
    // grows them by it, which loops for a row straddling the tab bar.
    let profile = PostListCollectionController()
    profile.extendsUnderTopBar = true
    profile.additionalSafeAreaInsets = UIEdgeInsets(top: 100, left: 0, bottom: 0, right: 0)
    profile.loadViewIfNeeded()
    profile.view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
    profile.view.layoutIfNeeded()
    let collection = try #require(profile.collectionView)
    #expect(collection.contentInsetAdjustmentBehavior == .automatic)
    #expect(collection.contentInset.top == -profile.view.safeAreaInsets.top)

    profile.extendsUnderTopBar = false
    #expect(collection.contentInset.top == 0)
  }

  @Test("One controller restores normalized tab offsets without crossing account/profile keys")
  func restoresOffsetsAfterSnapshots() async throws {
    let controller = PostListCollectionController()
    controller.rowViewBuilder = { _ in AnyView(Color.clear.frame(height: 100)) }
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
    controller.view.layoutIfNeeded()
    let collection = try #require(controller.collectionView)
    collection.contentInsetAdjustmentBehavior = .never
    collection.contentInset = UIEdgeInsets(top: 44, left: 0, bottom: 0, right: 0)
    var reportedOffset: CGFloat?
    controller.onScrollOffsetChanged = { reportedOffset = $0 }
    defer { controller.cancelTasks() }

    let entries = try (0..<60).map { index -> PostListEntry in
      let uri = try ATProtocolURI(uriString: "at://did:plc:scrollfixture/app.bsky.feed.post/\(index)")
      let bookmark = AppBskyBookmarkDefs.BookmarkView(
        subject: .init(uri: uri, cid: CID.fromDAGCBOR(Data("post-\(index)".utf8))),
        item: .appBskyFeedDefsNotFoundPost(.init(uri: uri, notFound: true))
      )
      return .bookmark(EquatableBox(bookmark))
    }
    func apply(_ key: String, requestID: Int = 0) {
      controller.updateScrollPosition(key: key, requestID: requestID)
      controller.setEntries(entries, hasMore: false, isLoadingMore: false, footerState: .hidden)
    }
    func scroll(_ normalizedOffset: CGFloat) {
      collection.setContentOffset(
        CGPoint(x: 0, y: normalizedOffset - collection.adjustedContentInset.top), animated: false
      )
    }

    apply("account-a/profile-a/posts")
    try await expectOffset(0, in: controller)
    scroll(320)
    #expect(abs((reportedOffset ?? -1) - 320) < 1)

    // Save using the old inset; restore using the new inset, not the old raw y.
    controller.updateScrollPosition(key: "account-a/profile-a/replies", requestID: 0)
    collection.contentInset.top = 88
    controller.setEntries(entries, hasMore: false, isLoadingMore: false, footerState: .hidden)
    try await expectOffset(0, in: controller)
    scroll(180)

    apply("account-a/profile-a/posts")
    try await expectOffset(320, in: controller)
    apply("account-b/profile-a/posts")
    try await expectOffset(0, in: controller)
    scroll(120)
    apply("account-a/profile-b/posts")
    try await expectOffset(0, in: controller)
    scroll(80)
    apply("account-a/profile-a/replies")
    try await expectOffset(180, in: controller)
    apply("account-a/profile-a/posts")
    try await expectOffset(320, in: controller)

    apply("account-a/profile-a/posts", requestID: 1)
    try await expectOffset(0, in: controller)
    #expect(abs(reportedOffset ?? -1) < 1)
    #expect(collection.numberOfItems(inSection: 0) == 60)
    #expect(collection.visibleCells.count < entries.count)
  }

  /// The profile list prepends the pinned post to rows the view model already de-duplicated,
  /// and relies on the controller to drop any id it has already placed. That depends on
  /// Petrel's `FeedViewPost.id` telling a repost apart from its original.
  @Test("Repeated feed rows keep their first position and a repost keeps its own row")
  func repeatedFeedRowsAreDroppedButRepostsKept() throws {
    let original = try ProfilePostIdentityTests.makeFeedViewPost(rkey: "shared")
    let repost = try ProfilePostIdentityTests.makeFeedViewPost(rkey: "shared", repostedBy: "did:plc:reposter")
    let controller = PostListCollectionController()

    controller.setEntries(
      [original, repost, original].map { .feedPost(EquatableBox($0)) },
      hasMore: false, isLoadingMore: false, footerState: .hidden
    )

    #expect(controller.entries.map(\.id) == [original.id, repost.id])
  }

  private func expectOffset(_ expected: CGFloat, in controller: PostListCollectionController) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    var offset: CGFloat = .infinity
    repeat {
      try await Task.sleep(for: .milliseconds(20))
      controller.view.layoutIfNeeded()
      controller.collectionView.layoutIfNeeded()
      offset = controller.collectionView.contentOffset.y + controller.collectionView.adjustedContentInset.top
    } while abs(offset - expected) >= 1 && ContinuousClock.now < deadline
    #expect(abs(offset - expected) < 1, "Expected normalized offset \(expected), got \(offset)")
  }
}
#endif
