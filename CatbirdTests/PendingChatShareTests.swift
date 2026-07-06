@testable import Catbird
import CatbirdMLSCore
import Foundation
import Petrel
import Testing

struct PendingChatShareTests {
  @Test("Preview embed carries post identity and author")
  func previewEmbedCarriesPostIdentity() throws {
    let uri = try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/3kabc")
    let cid = try CID.parse("bafyreib2rxk3rw6lvbrpq3vf5oh6nsm7pyf7cjcvvcy4pw3rbhgyk5cpp4")
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:author"),
      handle: try Handle(handleString: "author.test"),
      displayName: "Author",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
    let post = AppBskyFeedDefs.PostView(
      uri: uri,
      cid: cid,
      author: author,
      record: .object([:]),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 2,
      repostCount: 3,
      likeCount: 4,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000)),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )

    let embed = PendingChatShare.makePreviewEmbed(from: post)

    guard case .post(let postEmbed) = embed else {
      Issue.record("Expected .post embed, got \(embed)")
      return
    }
    #expect(postEmbed.uri == uri.uriString())
    #expect(postEmbed.authorHandle == "author.test")
    #expect(postEmbed.likeCount == 4)
  }
}
