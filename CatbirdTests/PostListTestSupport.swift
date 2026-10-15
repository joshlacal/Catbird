#if os(iOS)
import Petrel
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
}
#endif
