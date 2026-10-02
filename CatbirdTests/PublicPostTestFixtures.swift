import Foundation
import Petrel

enum PublicPostTestFixtures {
  static func makePostView(
    uri: ATProtocolURI,
    authorDID: DID,
    text: String = "Hello"
  ) -> AppBskyFeedDefs.PostView {
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: authorDID,
      handle: try! Handle(handleString: "author.test"),
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
    return AppBskyFeedDefs.PostView(
      uri: uri,
      cid: CID.fromDAGCBOR(Data("cid-test".utf8)),
      author: author,
      record: .knownType(
        AppBskyFeedPost(
          text: text,
          entities: nil,
          facets: nil,
          reply: nil,
          embed: nil,
          langs: nil,
          labels: nil,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
  }

}
