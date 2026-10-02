#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

@MainActor
struct ThreadResizabilityTests {
  private func traits(_ category: UIContentSizeCategory = .large, regular: Bool = false) -> UITraitCollection {
    UITraitCollection {
      $0.preferredContentSizeCategory = category
      $0.horizontalSizeClass = regular ? .regular : .compact
    }
  }

  @Test func cachedHeightsFollowWidthAndDynamicType() throws {
    let calculator = PostHeightCalculator(config: .standard(containerWidth: 600, traitCollection: traits()))
    let post = try makePost()
    let wideHeight = calculator.calculateHeight(for: post)
    #expect(calculator.updateLayout(containerWidth: 300, traitCollection: traits()))
    let narrowHeight = calculator.calculateHeight(for: post)
    #expect(narrowHeight > wideHeight)
    #expect(!calculator.updateLayout(containerWidth: 300, traitCollection: traits()))
    #expect(calculator.updateLayout(containerWidth: 300, traitCollection: traits(.accessibilityExtraExtraExtraLarge)))
    #expect(calculator.calculateHeight(for: post) > narrowHeight)
    #expect(calculator.updateLayout(containerWidth: 600, traitCollection: traits()))
    #expect(calculator.calculateHeight(for: post) == wideHeight)
    #expect(!calculator.updateLayout(containerWidth: 0, traitCollection: traits()))
    #expect(!calculator.updateLayout(containerWidth: .nan, traitCollection: traits()))
    #expect(calculator.calculateHeight(for: post) == wideHeight)
  }

  @Test func galleryEstimatesFollowLocalSizeClassAtTheSameWidth() {
    let compact = PostHeightCalculator.Config.standard(containerWidth: 500, traitCollection: traits())
    let regular = PostHeightCalculator.Config.standard(containerWidth: 500, traitCollection: traits(regular: true))
    #expect(compact.galleryCarouselHeight == GalleryEmbedView.compactCarouselHeight)
    #expect(regular.galleryCarouselHeight == GalleryEmbedView.regularCarouselHeight)
    let calculator = PostHeightCalculator(config: compact)
    #expect(calculator.updateLayout(containerWidth: 500, traitCollection: traits(regular: true)))
    #expect(!calculator.updateLayout(containerWidth: 500, traitCollection: traits(regular: true)))
  }

  #if !targetEnvironment(macCatalyst)
  @Test func scrollRestorationUsesTheReceivingViewsCurrentScale() throws {
    let view = AnchorCollectionView(frame: CGRect(x: 0, y: 0, width: 300, height: 500), collectionViewLayout: UICollectionViewFlowLayout())
    view.contentSize = CGSize(width: 300, height: 2000)
    let system = OptimizedScrollPreservationSystem()
    let anchor = OptimizedScrollPreservationSystem.PreciseScrollAnchor(
      indexPath: IndexPath(item: 0, section: 0), postId: "post", contentOffset: .zero,
      viewportRelativeY: 0, itemFrameY: 100.26, itemHeight: 80, visibleHeightInViewport: 80,
      timestamp: 0, displayScale: 3
    )
    view.testDisplayScale = 2
    let atTwo = try #require(system.calculateTargetOffset(for: anchor, newPostIds: ["post"], in: view))
    #expect(abs(atTwo.y - 100.5) < 0.0001)
    view.testDisplayScale = 3
    let atThree = try #require(system.calculateTargetOffset(for: anchor, newPostIds: ["post"], in: view))
    #expect(abs(atThree.y - (301.0 / 3)) < 0.0001)
  }

  private final class AnchorCollectionView: UICollectionView {
    var testDisplayScale: CGFloat = 3

    override var traitCollection: UITraitCollection {
      super.traitCollection.modifyingTraits { $0.displayScale = testDisplayScale }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
      let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
      attributes.frame = CGRect(x: 0, y: 100.26, width: 300, height: 80)
      return attributes
    }
  }
  #endif

  private func makePost() throws -> AppBskyFeedDefs.PostView {
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:resizability"),
      handle: try Handle(handleString: "resize.test"),
      displayName: "Resize", pronouns: nil, avatar: nil, associated: nil, viewer: nil,
      labels: nil, createdAt: nil, verification: nil, status: nil, debug: nil
    )
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:resizability/app.bsky.feed.post/one"),
      cid: CID.fromDAGCBOR(Data("resizability".utf8)),
      author: author,
      record: .knownType(AppBskyFeedPost(
        text: String(repeating: "Text that wraps as the available width changes. ", count: 12),
        entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil, tags: nil,
        createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0))
      )),
      embed: nil, bookmarkCount: nil, replyCount: 0, repostCount: 0, likeCount: 0,
      quoteCount: nil, indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)),
      viewer: nil, labels: nil, threadgate: nil, debug: nil
    )
  }
}
#endif
