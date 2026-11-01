import Foundation
import Testing

@testable import Catbird

// A DM shared-post card shows a neutral placeholder until its record is confirmed under the viewer's
// labelers. The author handle and text an MLS payload carries come from the sender, so they must never
// reach the card, in any state.

@Suite("DM shared-post card placeholder")
struct ChatSharedPostCardTests {
  private static let uri = "at://did:plc:sharedpostauthor/app.bsky.feed.post/shared"
  private static let handle = "labeled-author.test"
  private static let text = "Words a subscribed labeler hides"

  private static var mlsPost: UnifiedEmbed {
    .post(PostEmbedData(
      uri: uri, cid: "bafyreisharedpost", authorDID: "did:plc:sharedpostauthor", authorHandle: handle, text: text))
  }

  @Test("An MLS shared post's sender-supplied handle and text never reach the placeholder")
  func mlsPayloadNeverReachesThePlaceholder() throws {
    let card = try #require(ChatSharedPostCard(embed: Self.mlsPost))
    let shown = [card.placeholder.title, card.placeholder.detail, card.placeholder.accessibilityLabel]

    #expect(card.uri == Self.uri)
    for string in shown {
      #expect(!string.contains(Self.handle))
      #expect(!string.contains(Self.text))
      #expect(!string.contains("did:plc:sharedpostauthor"))
    }
  }

  @Test("MLS and Bluesky DM shared posts get the same card and placeholder")
  func mlsAndBlueskyCardsMatch() throws {
    let bluesky = try #require(ChatSharedPostCard(
      embed: .blueskyRecord(recordData: BlueskyRecordEmbedData(uri: Self.uri, cid: "bafyreisharedpost"))))
    let mls = try #require(ChatSharedPostCard(embed: Self.mlsPost))

    #expect(bluesky == mls)
    #expect(bluesky.placeholder == ChatSharedPostCard.placeholder)
    #expect(ChatSharedPostCard.placeholder.title == "Shared Post")
    #expect(ChatSharedPostCard.placeholder.accessibilityLabel == "Shared post")
  }

  @Test("An MLS post with no handle or text gets the same placeholder")
  func emptyMLSPayloadMatches() throws {
    let bare = try #require(ChatSharedPostCard(embed: .post(PostEmbedData(
      uri: Self.uri, cid: "bafyreisharedpost", authorDID: "did:plc:sharedpostauthor", authorHandle: nil, text: nil))))
    let full = try #require(ChatSharedPostCard(embed: Self.mlsPost))

    #expect(bare == full)
  }

  @Test("Embeds that are not shared posts build no card")
  func otherEmbedsBuildNoCard() throws {
    let url = try #require(URL(string: "https://media.tenor.com/clip.mp4"))

    #expect(ChatSharedPostCard(embed: .gif(GIFEmbedData(url: url, previewURL: nil, width: 1, height: 1))) == nil)
    #expect(ChatSharedPostCard(embed: .link(LinkEmbedData(
      url: url, title: "Title", description: nil, thumbnailURL: nil))) == nil)
    #expect(ChatSharedPostCard(embed: .groupInvite(.unavailable(code: nil))) == nil)
  }
}
