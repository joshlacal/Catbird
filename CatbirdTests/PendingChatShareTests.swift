@testable import Catbird
import Petrel
import Testing

struct PendingChatShareTests {
  @Test("Shared-post preview carries its author and text")
  func previewEmbedCarriesAuthorAndText() throws {
    let post = PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/3kabc"),
      authorDID: try DID(didString: "did:plc:author"),
      text: "A post to discuss"
    )

    let preview = PendingChatShare.makePreviewEmbed(from: post)

    #expect(preview.authorDisplayName == "Author")
    #expect(preview.authorHandle == "author.test")
    #expect(preview.text == "A post to discuss")
  }

  @Test("An unavailable record preserves the author without inventing preview text")
  func unknownRecordHasNoPreviewText() throws {
    let post = PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/3kabc"),
      authorDID: try DID(didString: "did:plc:author"),
      record: .object([:])
    )

    let preview = PendingChatShare.makePreviewEmbed(from: post)

    #expect(preview.authorHandle == "author.test")
    #expect(preview.text == "")
  }
}
