#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed row height caching", .serialized)
struct FeedRowHeightCachingTests {
  private static let width = 390
  private static let renderedHeight: CGFloat = 212
  private static let staleHeight: CGFloat = 80

  @Test("A cached height only answers the first measurement after configuration")
  func cachedHeightServesOnlyTheFirstPass() throws {
    let fixture = try Fixture()
    fixture.cache.store(height: Self.staleHeight, for: fixture.postID, width: Self.width,
      fontGeneration: 0, contentSizeCategory: .large, contentSignature: fixture.signature)
    fixture.cell.markConfigured()

    #expect(fixture.measure() == Self.staleHeight)
    // A later self-sizing pass reflects the hosted content, never the cached value.
    #expect(abs(fixture.measure() - Self.renderedHeight) < 1)
    let stored = try #require(fixture.cachedHeight())
    #expect(abs(stored - Self.renderedHeight) < 1)
  }

  @Test("Heights measured with transient row state are never cached")
  func transientStateIsNotCached() throws {
    let fixture = try Fixture()
    fixture.cell.markConfigured()
    _ = fixture.measure()
    #expect(fixture.cachedHeight() != nil)

    fixture.cell.markHeightNeedsRecalculation()
    #expect(fixture.cachedHeight() == nil)
    _ = fixture.measure()
    #expect(fixture.cachedHeight() == nil)

    // Reuse starts from the post's default state, so its measurement is cacheable again.
    fixture.cell.prepareForReuse()
    fixture.configure()
    fixture.cell.markConfigured()
    _ = fixture.measure()
    #expect(fixture.cachedHeight() != nil)
  }

  // MARK: - Fixture

  @MainActor
  private final class Fixture {
    let cache = FeedRowHeightCache()
    let cell = FeedPostCollectionViewCell(
      frame: CGRect(x: 0, y: 0, width: CGFloat(FeedRowHeightCachingTests.width), height: 44))
    let postID: String
    let signature: FeedPostContentSignature

    init() throws {
      let post = try Self.makePost()
      postID = post.id
      signature = FeedPostContentSignature(post)
      configure()
    }

    func configure() {
      cell.heightCache = cache
      cell.postID = postID
      cell.contentSignature = signature
      cell.fontGeneration = 0
      cell.contentSizeCategory = .large
      cell.contentConfiguration = UIHostingConfiguration {
        Color.clear.frame(height: FeedRowHeightCachingTests.renderedHeight)
      }
      .margins(.all, 0)
    }

    func measure() -> CGFloat {
      let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
      attributes.frame = CGRect(x: 0, y: 0, width: CGFloat(FeedRowHeightCachingTests.width), height: 44)
      return cell.preferredLayoutAttributesFitting(attributes).size.height
    }

    func cachedHeight() -> CGFloat? {
      cache.height(for: postID, width: FeedRowHeightCachingTests.width, fontGeneration: 0,
        contentSizeCategory: .large, contentSignature: signature)
    }

    private static func makePost() throws -> CachedFeedViewPost {
      let record = AppBskyFeedPost(
        text: "Height fixture", entities: nil, facets: nil, reply: nil, embed: nil,
        langs: nil, labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
      let author = AppBskyActorDefs.ProfileViewBasic(
        did: try DID(didString: "did:plc:heightfixture"),
        handle: try Handle(handleString: "height.test"), displayName: "Height",
        pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
        createdAt: nil, verification: nil, status: nil, debug: nil)
      let post = AppBskyFeedDefs.PostView(
        uri: try ATProtocolURI(uriString: "at://did:plc:heightfixture/app.bsky.feed.post/one"),
        cid: CID.fromDAGCBOR(Data("cid-height".utf8)), author: author,
        record: .knownType(record), embed: nil, bookmarkCount: nil,
        replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
        indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)),
        viewer: nil, labels: nil, threadgate: nil, debug: nil)
      let decoded = AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil,
        feedContext: nil, reqId: nil)
      return try #require(CachedFeedViewPost(from: decoded, feedType: "timeline"))
    }
  }
}
#endif
